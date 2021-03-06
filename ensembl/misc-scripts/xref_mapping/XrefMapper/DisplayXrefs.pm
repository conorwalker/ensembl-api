package XrefMapper::DisplayXrefs;
use strict;

use vars '@ISA';
@ISA = qw{ XrefMapper::BasicMapper };

use warnings;
use XrefMapper::BasicMapper;

use Cwd;
use DBI;
use File::Basename;
use IPC::Open3;

my %genes_to_transcripts;
my %translation_to_transcript;
my %transcript_to_translation;
my %transcript_length;


#
# ignore should be some sql to return object_xref_ids that should be ignored. FOR full mode METHOD 
# ignore should return regexp and source name as key for update METHODS
#

sub gene_description_sources {

  return ("RFAM",
          "RNAMMER",
          "TRNASCAN_SE",
	  "miRBase",
          "HGNC",
          "IMGT/GENE_DB",
	  "Uniprot/SWISSPROT",
	  "RefSeq_peptide",
	  "RefSeq_dna",
	  "Uniprot/Varsplic",
	  "Uniprot/SPTREMBL");

}

sub gene_description_filter_regexps {

  return ();

}

sub transcript_display_xref_sources {
  my $self     = shift;

  my @list = qw(HGNC
                MGI
                Clone_based_vega_gene
                Clone_based_ensembl_gene
                HGNC_transcript_name
                MGI_transcript_name
                Clone_based_vega_transcript
                Clone_based_ensembl_transcript
                miRBase
                RFAM
                IMGT/GENE_DB
                SGD
                flybase_symbol
                Anopheles_symbol
                Genoscope_annotated_gene
                Uniprot/SWISSPROT
                Uniprot/Varsplic
                Uniprot/SPTREMBL
                EntrezGene);

  my %ignore;
  

  # Both methods

  $ignore{"EntrezGene"} =(<<'IEG');
SELECT DISTINCT ox.object_xref_id
  FROM object_xref ox, dependent_xref dx, 
       xref xmas, xref xdep, 
       source smas, source sdep
    WHERE ox.xref_id = dx.dependent_xref_id AND
          dx.dependent_xref_id = xdep.xref_id AND
          dx.master_xref_id = xmas.xref_id AND
          xmas.source_id = smas.source_id AND
          xdep.source_id = sdep.source_id AND
          smas.name like "Refseq%predicted" AND
          sdep.name like "EntrezGene" AND
          ox.ox_status = "DUMP_OUT"
IEG

    $ignore{"Uniprot/SPTREMBL"} =(<<BIGN);
SELECT object_xref_id
    FROM object_xref JOIN xref USING(xref_id) JOIN source USING(source_id)
     WHERE ox_status = 'DUMP_OUT' AND name = 'Uniprot/SPTREMBL' 
      AND priority_description = 'protein_evidence_gt_2'
BIGN


  return [\@list,\%ignore];

}


sub new {
  my($class, $mapper) = @_;

  my $self ={};
  bless $self,$class;
  $self->core($mapper->core);
  $self->xref($mapper->xref);
  $self->mapper($mapper);
  $self->verbose($mapper->verbose);
  return $self;
}


sub mapper{
  my ($self, $arg) = @_;

  (defined $arg) &&
    ($self->{_mapper} = $arg );
  return $self->{_mapper};
}



sub genes_and_transcripts_attributes_set{
  # Runs build_transcript_and_gene_display_xrefs,
  # build_gene_transcript_status and
  # build_meta_timestamp, and, if "-upload" is set, uses the SQL files
  # produced to update the core database.

  my ($self, $noxref_database) = @_;

  my $status;
  if(defined($noxref_database)){
    $status = "none";
  }
  else{
    $status = $self->mapper->xref_latest_status();
  }
     
  if($self->mapper->can("set_display_xrefs")){
    $self->mapper->set_display_xrefs();
  }
  else{
    $self->set_display_xrefs();
  }	
  my $sth_stat = $self->xref->dbc->prepare("insert into process_status (status, date) values('display_xref_done',now())");
  $sth_stat->execute();
  $sth_stat->finish;
  if($self->mapper->can("set_gene_descriptions")){
    $self->mapper->set_gene_descriptions();
  }
  else{
      $self->set_gene_descriptions();
    }	
  $self->set_status(); # set KNOWN,NOVEL etc 
  #  }

  $self->build_meta_timestamp;

  # Special removal of LRG transcript display xref, xref and object_xrefs;

  my $sth_lrg =  $self->core->dbc->prepare('DELETE ox, x  FROM object_xref ox, xref x, transcript t WHERE ox.xref_id = x.xref_id and t.display_xref_id = x.xref_id and t.stable_id like "LRG%"');
  $sth_lrg->execute;

  $sth_lrg = $self->core->dbc->prepare('UPDATE transcript SET display_xref_id = null WHERE stable_id like "LRG%" ');
  $sth_lrg->execute;

  #End of Special

  $sth_lrg = $self->core->dbc->prepare("UPDATE xref SET info_text=null WHERE info_text=''");
  $sth_lrg->execute;


  if(!defined($noxref_database)){
    my $sth_stat = $self->xref->dbc->prepare("insert into process_status (status, date) values('gene_description_done',now())");
    $sth_stat->execute();
    $sth_stat->finish;
  }

  return 1;
}

sub set_gene_descriptions_from_display_xref{
  my $self = shift;
  
  $self->set_gene_descriptions(1);
}




sub set_display_xrefs_from_stable_table{
  my $self = shift;
  print "Setting Transcript and Gene display_xrefs from xref database into core and setting the desc\n" if ($self->verbose);

  my $xref_offset = $self->get_meta_value("xref_offset");

  print "Using xref_off set of $xref_offset\n" if($self->verbose);

  my $reset_sth = $self->core->dbc->prepare("UPDATE gene SET display_xref_id = null");
  $reset_sth->execute();
  $reset_sth->finish;
 
  $reset_sth = $self->core->dbc->prepare("UPDATE transcript SET display_xref_id = null");
  $reset_sth->execute();
  $reset_sth->finish;

  $reset_sth = $self->core->dbc->prepare("UPDATE gene SET description = null");
  $reset_sth->execute();
  $reset_sth->finish;


  my %name_to_external_name;
  my $sql = "select external_db_id, db_name, db_display_name from external_db";
  my $sth = $self->core->dbc->prepare($sql);
  $sth->execute();
  my ($id, $name, $display_name);
  $sth->bind_columns(\$id, \$name, \$display_name);
  while($sth->fetch()){
    $name_to_external_name{$name} = $display_name;
   }
  $sth->finish;

  my %source_id_to_external_name;

  $sql = 'select s.source_id, s.name from source s, xref x where x.source_id = s.source_id group by s.source_id'; # only get those of interest
  $sth = $self->xref->dbc->prepare($sql);
  $sth->execute();
  $sth->bind_columns(\$id, \$name);

  while($sth->fetch()){
     if(defined($name_to_external_name{$name})){
      $source_id_to_external_name{$id} = $name_to_external_name{$name};
    }
  }
  $sth->finish;


  my $update_gene_sth = $self->core->dbc->prepare("UPDATE gene g SET g.display_xref_id= ? WHERE g.gene_id=?");
  my $update_gene_desc_sth = $self->core->dbc->prepare("UPDATE gene g SET g.description= ? WHERE g.gene_id=?");

  my $update_tran_sth = $self->core->dbc->prepare("UPDATE transcript t SET t.display_xref_id= ? WHERE t.transcript_id=?");

  my $get_gene_display_xref = $self->xref->dbc->prepare("SELECT gsi.internal_id, gsi.display_xref_id, x.description ,x.source_id, x.accession
                                                              FROM gene_stable_id gsi, xref x 
                                                                 WHERE gsi.display_xref_id = x.xref_id");

  my $get_tran_display_xref = $self->xref->dbc->prepare("SELECT gsi.internal_id, gsi.display_xref_id from transcript_stable_id gsi");

  $reset_sth = $self->xref->dbc->prepare("UPDATE gene_stable_id gsi SET gsi.desc_set=0");
  $reset_sth->execute();

  my $set_desc_done_sth = $self->xref->dbc->prepare("UPDATE gene_stable_id gsi SET gsi.desc_set=1 WHERE gsi.internal_id=?");

  $get_gene_display_xref->execute();
  my $xref_id;
  my $desc;
  my $gene_id;
  my $source_id;
  my $label;
  $get_gene_display_xref->bind_columns(\$gene_id, \$xref_id, \$desc, \$source_id, \$label);
  my $gene_count =0;
  while($get_gene_display_xref->fetch()){

    $update_gene_sth->execute($xref_id+$xref_offset, $gene_id);

    if (defined($desc) and $desc ne "") {
      $desc .= " [Source:".$source_id_to_external_name{$source_id}.";Acc:".$label."]";
      $update_gene_desc_sth->execute($desc,$gene_id);
      $set_desc_done_sth->execute($gene_id);
      $gene_count++;
    }

  }

  $update_gene_desc_sth->finish;
  $update_gene_sth->finish;

  print "$gene_count gene descriptions added\n" if($self->verbose);

  $get_tran_display_xref->execute();
  my $tran_id;
  $get_tran_display_xref->bind_columns(\$tran_id, \$xref_id);

  while($get_tran_display_xref->fetch()){
    if(defined($xref_id)){
      $update_tran_sth->execute($xref_id+$xref_offset, $tran_id);
      if(!defined($tran_id) || !defined($xref_id) || !defined($xref_offset)){
	print "PROB: tran_id = $tran_id\nxref_id = $xref_id\n$xref_offset = $xref_offset\n";
      }
    }
  }	
}



sub set_status{
  my $self = shift;

# set all genes to NOVEL

  
  my $reset_sth = $self->core->dbc->prepare('UPDATE gene SET status = "NOVEL"');
  $reset_sth->execute();
  $reset_sth->finish;

  $reset_sth = $self->core->dbc->prepare('UPDATE transcript SET status = "NOVEL"');
  $reset_sth->execute();
  $reset_sth->finish;
  
  my $update_gene_sth = $self->core->dbc->prepare('UPDATE gene SET status = ? where gene_id = ?');
  my $update_tran_sth = $self->core->dbc->prepare('UPDATE transcript SET status = ? where transcript_id = ?');

  
my $known_xref_sql =(<<DXS);
select  distinct 
        IF (ox.ensembl_object_type = 'Gene',        gtt_gene.gene_id,
        IF (ox.ensembl_object_type = 'Transcript',  gtt_transcript.gene_id,
                                                    gtt_translation.gene_id)) AS gene_id,

        IF (ox.ensembl_object_type = 'Gene',        gtt_gene.transcript_id,
        IF (ox.ensembl_object_type = 'Transcript',  gtt_transcript.transcript_id,
                                                    gtt_translation.transcript_id)) AS transcript_id
from    (   source s
      join    (   xref x
        join      (   object_xref ox
                  ) using (xref_id)
              ) using (source_id)
          )
  left join gene_transcript_translation gtt_gene
    on (gtt_gene.gene_id = ox.ensembl_id)
  left join gene_transcript_translation gtt_transcript
    on (gtt_transcript.transcript_id = ox.ensembl_id)
  left join gene_transcript_translation gtt_translation
    on (gtt_translation.translation_id = ox.ensembl_id)
where   ox.ox_status = 'DUMP_OUT'
        AND s.status like 'KNOWN%'
        AND ox.linkage_type <> 'DEPENDENT'
        ORDER BY gene_id DESC, transcript_id DESC
DXS


  my $last_gene = 0;

  my $known_xref_sth = $self->xref->dbc->prepare($known_xref_sql);

  $known_xref_sth->execute();
  my ($gene_id, $transcript_id);  # remove labvel after testig it is not needed
  $known_xref_sth->bind_columns(\$gene_id, \$transcript_id);
  while($known_xref_sth->fetch()){
    if($gene_id != $last_gene){
      $update_gene_sth->execute("KNOWN",$gene_id);
      $last_gene = $gene_id;
    } 
    $update_tran_sth->execute("KNOWN",$transcript_id);
  }


  # 1) load list of stable_gene_id from xref database and covert to internal id in
  #    new core database table.
  #    Use this table to reset havana gene/transcript status.

  if(!scalar(keys %genes_to_transcripts)){
    $self->build_genes_to_transcripts();
  }

  #
  # Reset status for those from vega
  #

#  my %gene_id_to_status;
  my $gene_status_sth = $self->xref->dbc->prepare("SELECT gsi.internal_id, hs.status FROM gene_stable_id gsi, havana_status hs WHERE hs.stable_id = gsi.stable_id") 
    || die "Could not prepare gene_status_sth";

  $gene_status_sth->execute();
  my ($internal_id, $status);
  $gene_status_sth->bind_columns(\$internal_id,\$status);
  while($gene_status_sth->fetch()){
#    $gene_id_to_status{$internal_id} = $status;
    $update_gene_sth->execute($status, $internal_id);
  }
  $gene_status_sth->finish();

  #
  # need to create a transcript_id to status hash
  #

#  my %transcript_id_to_status;
  my $transcript_status_sth = $self->xref->dbc->prepare("SELECT tsi.internal_id, hs.status FROM transcript_stable_id tsi, havana_status hs WHERE hs.stable_id = tsi.stable_id") 
    || die "Could not prepare transcript_status_sth";

  $transcript_status_sth->execute();
  $transcript_status_sth->bind_columns(\$internal_id,\$status);
  while($transcript_status_sth->fetch()){
    #    $transcript_id_to_status{$internal_id} = $status;
    $update_tran_sth->execute($status,$internal_id);  
  }
  $transcript_status_sth->finish();


  $known_xref_sth->finish;
  $update_gene_sth->finish;
  $update_tran_sth->finish;
  

}


sub load_translation_to_transcript{
  my ($self) = @_;

  my $sth = $self->core->dbc->prepare("SELECT translation_id, transcript_id FROM translation");
  $sth->execute();
  
  my ($translation_id, $transcript_id);
  $sth->bind_columns(\$translation_id, \$transcript_id);
  
  while ($sth->fetch()) {
    $translation_to_transcript{$translation_id} = $transcript_id;
    $transcript_to_translation{$transcript_id} = $translation_id if ($translation_id);
  }
}


sub build_genes_to_transcripts {
  my ($self) = @_;

  my $sql = "SELECT gene_id, transcript_id, seq_region_start, seq_region_end FROM transcript";
  my $sth = $self->core->dbc->prepare($sql);
  $sth->execute();

  my ($gene_id, $transcript_id, $start, $end);
  $sth->bind_columns(\$gene_id, \$transcript_id, \$start, \$end);

  # Note %genes_to_transcripts is global
  while ($sth->fetch()) {
    push @{$genes_to_transcripts{$gene_id}}, $transcript_id;
    $transcript_length{$transcript_id} = $end- $start;
  }

  $sth->finish
}

sub build_gene_transcript_status{
  # Creates the files that contain the SQL needed to (re)set the
  # gene.status and transcript.status values
  my $self = shift;
  
  my $reset_sth = $self->core->dbc->prepare('UPDATE gene SET status = "NOVEL"');
  $reset_sth->execute();
  $reset_sth->finish;

  $reset_sth = $self->core->dbc->prepare('UPDATE transcript SET status = "NOVEL"');
  $reset_sth->execute();
  $reset_sth->finish;
  
  my $update_gene_sth = $self->core->dbc->prepare('UPDATE gene SET status = "KNOWN" where gene_id = ?');
  my $update_tran_sth = $self->core->dbc->prepare('UPDATE transcript SET status = "KNOWN" where transcript_id = ?');

  #create a hash known which ONLY has databases names of those that are KNOWN and KNOWNXREF
  my %known;
  my $sth = $self->core->dbc->prepare("select db_name from external_db where status in ('KNOWNXREF','KNOWN')");
  $sth->execute();
  my ($name);
  $sth->bind_columns(\$name);
  while($sth->fetch){
    $known{$name} = 1;
  }
  $sth->finish;
  
  
  # loop throught the gene and all transcript until you find KNOWN/KNOWNXREF as a status
  my $ensembl = $self->core;
  my $db = new Bio::EnsEMBL::DBSQL::DBAdaptor(-dbconn => $ensembl->dbc);
  my $gene_adaptor = $db->get_GeneAdaptor();

  my @genes = @{$gene_adaptor->fetch_all()};

  while (my $gene = shift @genes){
    my $gene_found = 0;
    my @dbentries = @{$gene->get_all_DBEntries()};
    foreach my $dbe (@dbentries){
      if(defined($known{$dbe->dbname})){
	$gene_found =1;
      }
    }
    my $one_tran_found = 0;
    foreach my $tr (@{$gene->get_all_Transcripts}){
      my $tran_found = 0;
      foreach my $dbe (@{$tr->get_all_DBLinks}){
	if(defined($known{$dbe->dbname})){
	  $tran_found = 1;
	  $one_tran_found = 1;
	}
      }
      if($tran_found or $gene_found){
	$update_tran_sth->execute($tr->dbID);
      }
    }
    if($gene_found or $one_tran_found){
      $update_gene_sth->execute($gene->dbID);
    }
  }

  return;
}

sub build_meta_timestamp{
  # Creates a file that contains the SQL needed to (re)set the 
  # 'xref.timestamp' key of the meta table.
  my $self = shift;


  my $sth = $self->core->dbc->prepare("DELETE FROM meta WHERE meta_key='xref.timestamp'");
  $sth->execute();
  $sth->finish;

  $sth = $self->core->dbc->prepare("INSERT INTO meta (meta_key,meta_value) VALUES ('xref.timestamp', NOW())");
  $sth->execute();
  $sth->finish;

  return;
}



sub set_display_xrefs{
  my $self = shift;


  print "Building Transcript and Gene display_xrefs using xref database\n" if ($self->verbose);

  my $xref_offset = $self->get_meta_value("xref_offset");

  print "Using xref_off set of $xref_offset\n" if($self->verbose);

  my $reset_sth = $self->core->dbc->prepare("UPDATE gene SET display_xref_id = null");
  $reset_sth->execute();
  $reset_sth->finish;
 
  $reset_sth = $self->core->dbc->prepare("UPDATE transcript SET display_xref_id = null");
  $reset_sth->execute();
  $reset_sth->finish;

  my $update_gene_sth = $self->core->dbc->prepare("UPDATE gene g SET g.display_xref_id= ? WHERE g.gene_id=?");
  my $update_tran_sth = $self->core->dbc->prepare("UPDATE transcript t SET t.display_xref_id= ? WHERE t.transcript_id=?");

 #get hash for sources in hash
  #get priority description

my $sql =(<<SQL); 
  CREATE TABLE display_xref_prioritys(
    source_id INT NOT NULL,
    priority       INT NOT NULL,
    PRIMARY KEY (source_id)
  ) COLLATE=latin1_swedish_ci ENGINE=InnoDB
SQL

  my $sth = $self->xref->dbc->prepare($sql);
  $sth->execute;
  $sth->finish;

  my $presedence;
  my $ignore; 
  if( $self->mapper->can("transcript_display_xref_sources") ){
    ($presedence, $ignore) = @{$self->mapper->transcript_display_xref_sources(1)}; # FULL update mode pass 1
  }
  else{
    ($presedence, $ignore) = @{$self->transcript_display_xref_sources(1)}; # FULL update mode pass 1
  }

  my $i=0;
  
  my $ins_p_sth = $self->xref->dbc->prepare("INSERT into display_xref_prioritys (source_id, priority) values(?, ?)");
  my $get_source_id_sth = $self->xref->dbc->prepare("select source_id from source where name like ? order by priority desc");

#
# So the higher the number the better then 
#


  my $last_name = "";
  print "Presedence for the display xrefs\n" if($self->verbose);
  foreach my $name (reverse (@$presedence)){
    $i++;
    $get_source_id_sth->execute($name);
    my $source_id;
    $get_source_id_sth->bind_columns(\$source_id);
    while($get_source_id_sth->fetch){
      $ins_p_sth->execute($source_id, $i);
      if($name ne $last_name){
	print "\t$name\t$i\n" if ($self->verbose);
      }	
      $last_name = $name;
    }
  }
  $ins_p_sth->finish;
  $get_source_id_sth->finish;


#
# Set status to 'NO_DISPLAY' for those that match the ignore REGEXP in object_xref
# Xrefs have already been dump to core etc so no damage done.
#

  my $update_ignore_sth = $self->xref->dbc->prepare('UPDATE object_xref SET ox_status = "NO_DISPLAY" where object_xref_id = ?');

  foreach my $ignore_sql (values %$ignore){
    print "IGNORE SQL: $ignore_sql\n" if($self->verbose);
    my $ignore_sth = $self->xref->dbc->prepare($ignore_sql);

    my $gene_count = 0;
    $ignore_sth->execute();
    my ($object_xref_id); 
    $ignore_sth->bind_columns(\$object_xref_id);
    while($ignore_sth->fetch()){    
      $update_ignore_sth->execute($object_xref_id);
    }
    $ignore_sth->finish;
  }
  $update_ignore_sth->finish;

#
# Do a similar thing for those with a display_label that is just numeric;
#

  $update_ignore_sth = $self->xref->dbc->prepare('UPDATE object_xref ox, source s, xref x SET ox_status = "NO_DISPLAY" where ox_status like "DUMP_OUT" and s.source_id = x.source_id and x.label REGEXP "^[0-9]+$" and ox.xref_id = x.xref_id');

  $update_ignore_sth->execute();
  $update_ignore_sth->finish;


#######################################################################

my $display_xref_sql =(<<DXS);
select  IF (ox.ensembl_object_type = 'Gene',        gtt_gene.gene_id,
        IF (ox.ensembl_object_type = 'Transcript',  gtt_transcript.gene_id,
          gtt_translation.gene_id)) AS gene_id,
        IF (ox.ensembl_object_type = 'Gene',        gtt_gene.transcript_id,
        IF (ox.ensembl_object_type = 'Transcript',  gtt_transcript.transcript_id,
          gtt_translation.transcript_id)) AS transcript_id,
        p.priority as priority,
        x.xref_id, 
        ox.ensembl_object_type as object_type,
        x.label  as label
from    (   display_xref_prioritys p
    join  (   source s
      join    (   xref x
        join      (   object_xref ox
          join        (   identity_xref ix
                      ) using (object_xref_id)
                  ) using (xref_id)
              ) using (source_id)
          ) using (source_id)
        )
  left join gene_transcript_translation gtt_gene
    on (gtt_gene.gene_id = ox.ensembl_id)
  left join gene_transcript_translation gtt_transcript
    on (gtt_transcript.transcript_id = ox.ensembl_id)
  left join gene_transcript_translation gtt_translation
    on (gtt_translation.translation_id = ox.ensembl_id)
where   ox.ox_status = 'DUMP_OUT'
order by    gene_id DESC, p.priority DESC, (ix.target_identity+ix.query_identity) DESC, ox.unused_priority DESC

DXS


########################################################################

  my %seen_transcript; # first time we see it is the best due to ordering :-)
                         # so either write data to database or store

  
#  my $gene_sth = $self->core->dbc->prepare("select x.display_label from gene g, xref x where g.display_xref_id = x.xref_id and g.gene_id = ?"); 
#  my $tran_sth = $self->core->dbc->prepare("select x.display_label from transcript t, xref x where t.display_xref_id = x.xref_id and t.transcript_id = ?"); 


  my $last_gene = 0;

  my $display_xref_sth = $self->xref->dbc->prepare($display_xref_sql);

  my $gene_count = 0;
  $display_xref_sth->execute();
  my ($gene_id, $transcript_id, $p, $xref_id, $type, $label);  # remove labvel after testig it is not needed
  $display_xref_sth->bind_columns(\$gene_id, \$transcript_id, \$p, \$xref_id, \$type, \$label);
  while($display_xref_sth->fetch()){
    if($gene_id != $last_gene){
      $update_gene_sth->execute($xref_id+$xref_offset, $gene_id);
      $last_gene = $gene_id;
      $gene_count++;
    } 
    if($type ne "Gene"){
      if(!defined($seen_transcript{$transcript_id})){ # not seen yet so its the best
	$update_tran_sth->execute($xref_id+$xref_offset, $transcript_id);
      }
      $seen_transcript{$transcript_id} = $xref_id+$xref_offset;
      
    }
  }
  $display_xref_sth->finish;
  $update_gene_sth->finish;
  $update_tran_sth->finish;

  #
  # reset the status to DUMP_OUT fro thise that where ignored for the display_xref;
  #

  my $reset_status_sth = $self->xref->dbc->prepare('UPDATE object_xref SET ox_status = "DUMP_OUT" where ox_status = "NO_DISPLAY"');
  $reset_status_sth->execute();
  $reset_status_sth->finish;

  $sth = $self->xref->dbc->prepare("drop table display_xref_prioritys");
  $sth->execute || die "Could not drop temp table display_xref_prioritys\n";
  $sth->finish;  


  print "Updated $gene_count display_xrefs for genes\n" if($self->verbose);
}


# Remove after sure everything is cool
sub check_label{
  my $self  = shift;
  my $id    = shift;
  my $label = shift;
  my $sth   = shift;
  my $type  = shift;

  $sth->execute($id);
  my $old_label;
  $sth->bind_columns(\$old_label);
  $sth->fetch;

  if($old_label ne $label){
    print "ERROR: $type ($id) has different display_xrefs ???  old:$old_label   new:$label\n";
  }
}



sub set_source_id_to_external_name {
    
    my $self = shift;
    my $name_to_external_name_href = shift;

    my $source_id_to_external_name_href = {};
    my $name_to_source_id_href = {};
    
    my $sql = 'select s.source_id, s.name from source s, xref x where x.source_id = s.source_id group by s.source_id'; # only get those of interest
    
    my $sth = $self->xref->dbc->prepare($sql);
    $sth->execute();
    my ($id, $name);
    $sth->bind_columns(\$id, \$name);
    while($sth->fetch()){
	if(defined($name_to_external_name_href->{$name})){
	    $source_id_to_external_name_href->{$id} = $name_to_external_name_href->{$name};
	    $name_to_source_id_href->{$name} = $id;
	}
	elsif($name =~ /notransfer$/){
	}
	else{
	    die "ERROR: Could not find $name in external_db table please add this too continue";
	}
    }
    
    $sth->finish;
    
    return ($source_id_to_external_name_href, $name_to_source_id_href);
}



sub set_gene_descriptions{
  my $self = shift;
  my $only_those_not_set = shift || 0;

  my $update_gene_desc_sth =  $self->core->dbc->prepare("UPDATE gene SET description = ? where gene_id = ?");

  if(!$only_those_not_set){
    my $reset_sth = $self->core->dbc->prepare("UPDATE gene SET description = null");
    $reset_sth->execute();
    $reset_sth->finish;
  }

  my %ignore;
  if($only_those_not_set){
    print "Only setting those not already set\n";
    my $sql = "select internal_id from gene_stable_id where desc_set = 1";
    my $sql_sth = $self->xref->dbc->prepare($sql);
    $sql_sth->execute;
    my $id;
    $sql_sth->bind_columns(\$id);
    while($sql_sth->fetch){
      $ignore{$id} = 1;
    }
    $sql_sth->finish;
  }	

  ##########################################
  # Get source_id to external_disaply_name #
  ##########################################

  my %name_to_external_name;
  my $sql = "select external_db_id, db_name, db_display_name from external_db";
  my $sth = $self->core->dbc->prepare($sql);
  $sth->execute();
  my ($id, $name, $display_name);
  $sth->bind_columns(\$id, \$name, \$display_name);
  while($sth->fetch()){
    $name_to_external_name{$name} = $display_name;
   }
  $sth->finish;
  
  my ($source_id_to_external_name_href, $name_to_source_id_href);
  if( $self->mapper->can("set_source_id_to_external_name") ){
      ($source_id_to_external_name_href, $name_to_source_id_href) = $self->mapper->set_source_id_to_external_name (\%name_to_external_name);
  }
  else{
      ($source_id_to_external_name_href, $name_to_source_id_href) = $self->set_source_id_to_external_name (\%name_to_external_name);
  }

  my %source_id_to_external_name = %$source_id_to_external_name_href;
  my %name_to_source_id = %$name_to_source_id_href;
  
  $sql =(<<SQL); 
  CREATE TABLE gene_desc_prioritys(
    source_id INT NOT NULL,
    priority       INT NOT NULL,
    PRIMARY KEY (source_id)
  ) COLLATE=latin1_swedish_ci ENGINE=InnoDB
SQL

  $sth = $self->xref->dbc->prepare($sql);
  $sth->execute;
  $sth->finish;

  my @presedence;
  my @regexps;
  if( $self->mapper->can("gene_description_sources") ){
    @presedence = $self->mapper->gene_description_sources();
  }
  else{
    @presedence = $self->gene_description_sources();
  }

  if( $self->mapper->can("gene_description_filter_regexps") ){
    @regexps = $self->mapper->gene_description_filter_regexps();
  }
  else{
    @regexps = $self->gene_description_filter_regexps();
  }


  my $i=0;
  
  my $ins_p_sth = $self->xref->dbc->prepare("INSERT into gene_desc_prioritys (source_id, priority) values(?, ?)");
  my $get_source_id_sth = $self->xref->dbc->prepare("select source_id from source where name like ?");

#
# So the higher the number the better then 
#


  print "Presedence for Gene Descriptions\n" if($self->verbose);
  my $last_name = "";
  foreach my $name (reverse (@presedence)){
    $i++;
    $get_source_id_sth->execute($name);
    my $source_id;
    $get_source_id_sth->bind_columns(\$source_id);
    while($get_source_id_sth->fetch){
      $ins_p_sth->execute($source_id, $i);
      if($last_name ne $name){
	print "\t$name\t$i\n" if ($self->verbose);
      }
      $last_name = $name;
    }
  }
  $ins_p_sth->finish;
  $get_source_id_sth->finish;


#######################################################################
my $gene_desc_sql =(<<DXS);
select  IF (ox.ensembl_object_type = 'Gene',        gtt_gene.gene_id,
        IF (ox.ensembl_object_type = 'Transcript',  gtt_transcript.gene_id,
          gtt_translation.gene_id)) AS gene_id,
        x.description AS description,
        s.source_id AS source_id,
        x.accession AS accession
from    (   gene_desc_prioritys p
    join  (   source s
      join    (   xref x
        join      (   object_xref ox
          join        (   identity_xref ix
                      ) using (object_xref_id)
                  ) using (xref_id)
              ) using (source_id)
          ) using (source_id)
        )
  left join gene_transcript_translation gtt_gene
    on (gtt_gene.gene_id = ox.ensembl_id)
  left join gene_transcript_translation gtt_transcript
    on (gtt_transcript.transcript_id = ox.ensembl_id)
  left join gene_transcript_translation gtt_translation
    on (gtt_translation.translation_id = ox.ensembl_id)
where   ox.ox_status = 'DUMP_OUT'
order by    gene_id desc,
            p.priority desc,
            (ix.target_identity+ix.query_identity) desc

DXS

######################################################################## 
  
  my $gene_sth = $self->core->dbc->prepare("select g.description from gene g where g.gene_id = ?"); 


  my $last_gene = 0;

  my %no_source_name_in_desc;
  if( $self->mapper->can("no_source_label_list") ){
    foreach my $name (@{$self->mapper->no_source_label_list()}){
      my $id = $name_to_source_id{$name};
      print "$name will not have [Source:...] info in desc\n";
      $no_source_name_in_desc{$id} = 1;
    }
  }

  my $gene_desc_sth = $self->xref->dbc->prepare($gene_desc_sql);

  $gene_desc_sth->execute();
  my ($gene_id, $desc,$source_id,$label);  # remove labvel after testig it is not needed
  $gene_desc_sth->bind_columns(\$gene_id, \$desc, \$source_id, \$label);
  
  my $gene_count = 0;
  while($gene_desc_sth->fetch()){
    #    print "$gene_id, $transcript_id, $p, $xref_id, $type, $label\n";
    
    next if(defined($ignore{$gene_id}));
    
    if($gene_id != $last_gene and defined($desc) ){
      my $filtered_description = $self->filter_by_regexp($desc, \@regexps);
      if ($filtered_description ne "") {
	if(!defined($no_source_name_in_desc{$source_id})){
	  $desc .= " [Source:".$source_id_to_external_name{$source_id}.";Acc:".$label."]";
	}
	$update_gene_desc_sth->execute($desc,$gene_id);
        $gene_count++;
	$last_gene = $gene_id;
      }
    }
  }
  $update_gene_desc_sth->finish;
  $gene_desc_sth->finish;
  print "$gene_count gene descriptions added\n";# if($self->verbose);
  


  $sth = $self->xref->dbc->prepare("drop table gene_desc_prioritys");
  $sth->execute || die "Could not drop temp table gene_desc_prioritys\n";
  $sth->finish;  
}

sub filter_by_regexp {

  my ($self, $str, $regexps) = @_;

  foreach my $regexp (@$regexps) {
    $str =~ s/$regexp//ig;
  }

  return $str;

}

sub check_desc{
  my $self  = shift;
  my $id    = shift;
  my $desc = shift;
  my $sth   = shift;
  my $type  = shift;

  $sth->execute($id);
  my $old_desc;
  $sth->bind_columns(\$old_desc);
  $sth->fetch;

  if($old_desc ne $desc){
    print "ERROR: $type ($id) has different descriptions ???  \n\told:$old_desc \n\tnew:$desc\n";
  }
}


1;
