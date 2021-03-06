use strict;

BEGIN {
    $| = 1;
    use Test;
    plan tests => 47;
}

my $loaded = 0;
END {print "not ok 1\n" unless $loaded;}

use Bio::EnsEMBL::Test::MultiTestDB;
use Bio::EnsEMBL::Test::TestUtils;

our $verbose = 0; #set to 1 to turn on debug printouts

$loaded = 1;
my $multi = Bio::EnsEMBL::Test::MultiTestDB->new();

ok(1);

my $db = $multi->get_DBAdaptor( 'core' );

ok($db);


# Exon specific tests

my $exonad = $db->get_ExonAdaptor();
my $slice_adaptor = $db->get_SliceAdaptor();

my $slice = $slice_adaptor->fetch_by_region('chromosome', '20',
                                            30_811_000,
                                            32_000_000);
ok($exonad);

my $exon = Bio::EnsEMBL::Exon->new();


$exon->start(1000);
ok(&test_getter_setter($exon, 'start', 200));

$exon->end(1400);
ok(&test_getter_setter($exon, 'end', 400));

$exon->strand(1);
ok(&test_getter_setter($exon, 'strand', -1));

$exon->phase(0);
ok(&test_getter_setter($exon, 'phase', -1));

$exon->slice( $slice );
ok(&test_getter_setter($exon, 'slice', $slice));

# should try to store (!)
$exon->end_phase( -1 );
ok(&test_getter_setter($exon, 'end_phase', 1));

ok( test_getter_setter( $exon, "created_date", time() ));
ok( test_getter_setter( $exon, "modified_date", time() ));

#
# find supporting evidence for the exon
#
my @evidence = ();
my @fs = ();
push @fs, @{$db->get_DnaAlignFeatureAdaptor->fetch_all_by_Slice($slice)};
push @fs, @{$db->get_ProteinAlignFeatureAdaptor->fetch_all_by_Slice($slice)};

while(my $f = shift @fs) {
  #debug("feature at: " . $f->start . "-" . $f->end);
  next if $f->start > $exon->end || $f->end < $exon->start;
  push(@evidence, $f);
  # cheat it into storing it again
  $f->dbID( undef );
  $f->adaptor( undef );
}

my $count = scalar(@evidence);
debug("adding $count supporting features");
$exon->add_supporting_features(@evidence);

$multi->hide( "core", "exon", "supporting_feature", 
	      "protein_align_feature", "dna_align_feature");

$exonad->store($exon);

ok($exon->dbID() && $exon->adaptor == $exonad);

# now test fetch_by_dbID

my $newexon = $exonad->fetch_by_dbID($exon->dbID);

ok($newexon);



debug("exon chr start  = " . $exon->start);
debug("exon chr end    = " . $exon->end);
debug("exon chr strand = " . $exon->strand);

debug("newexon start  = " . $newexon->start());
debug("newexon end    = " . $newexon->end());
debug("newexon strand = " . $newexon->strand());

ok($newexon->start == 30811999 &&
   $newexon->end == 30812399 &&
   $newexon->strand==1);


#
# Test transform to another slice
#
$slice = $exon->slice();
$slice = $db->get_SliceAdaptor->fetch_by_region('chromosome',
                                         $slice->seq_region_name,
                                         $slice->start + $exon->start - 11,
                                         $slice->start + $exon->end + 9);
$exon = $exon->transfer($slice);
debug("exon start  = " . $exon->start);
debug("exon end    = " . $exon->end);
debug("exon strand = " . $exon->strand);
ok($exon->start == 11 && $exon->end == 411 && $exon->strand==1);


#
# Test Transform to contig coord system
#
$exon = $exon->transform('contig');

debug("exon start  = " . $exon->start);
debug("exon end    = " . $exon->end);
debug("exon strand = " . $exon->strand);
debug("exon seq_region = " . $exon->slice->seq_region_name);

ok($exon->start == 913);
ok($exon->end   == 1313);
ok($exon->strand == 1);
ok($exon->slice->seq_region_name eq 'AL034550.31.1.118873');


#regression test, supporting evidence was lost post transform before...
my $se_count = scalar(@{$exon->get_all_supporting_features});

debug("Got $se_count supporting feature after transform");
ok($se_count == $count);

#make sure that supporting evidencewas stored correctly
$se_count = scalar(@{$newexon->get_all_supporting_features});
debug("Got $se_count from newly stored exon");
ok($se_count == $count);


# list_ functions
debug ("Exon->list_dbIDs");
my $ids = $exonad->list_dbIDs();
ok (@{$ids});

debug ("Exon->list_stable_ids");
my $stable_ids = $exonad->list_stable_ids();
ok (@{$stable_ids});

#hashkey
my $hashkey = $exon->hashkey();
debug($hashkey);

ok($hashkey eq $exon->slice->name . '-' . $exon->start . '-' .
               $exon->end . '-' . $exon->strand . '-' . $exon->phase .
               '-' . $exon->end_phase);

$multi->restore();


# regression test
# make sure that sequence fetching and caching is not broken
$exon->stable_id('TestID');
my $first_seq = $exon->seq();
my $second_seq = $exon->seq();

ok($first_seq->seq() && $first_seq->seq() eq $second_seq->seq());
ok($first_seq->display_id()  && $first_seq->display_id() eq $second_seq->display_id());


#
# test the remove method works
#

$multi->save("core", "exon", "supporting_feature",
  "dna_align_feature", "protein_align_feature");

my $ex_count = count_rows($db, 'exon');
my $supfeat_count = count_rows($db, 'supporting_feature');

$exon = $exonad->fetch_by_stable_id('ENSE00000859937');

# check the created and modified times
my @date_time = localtime( $exon->created_date());
ok( $date_time[3] == 6 && $date_time[4] == 11 && $date_time[5] == 104 );

@date_time = localtime( $exon->modified_date());
ok( $date_time[3] == 6 && $date_time[4] == 11 && $date_time[5] == 104 );


my $supfeat_minus = @{$exon->get_all_supporting_features()};

$exonad->remove($exon);

ok(count_rows($db, 'exon') == $ex_count - 1);
ok(count_rows($db, 'supporting_feature') == $supfeat_count - $supfeat_minus);

$multi->restore();

#
# tests for multiple versions of transcripts in a database
#

$exon = $exonad->fetch_by_stable_id('ENSE00001109603');
debug("fetch_by_stable_id");
ok( $exon->dbID == 162033 );

my @exons = @{ $exonad->fetch_all_versions_by_stable_id('ENSE00001109603') };
debug("fetch_all_versions_by_stable_id");
ok( scalar(@exons) == 1 );

# store/update tests

$multi->hide( "core", "exon", "supporting_feature", 
	      "protein_align_feature", "dna_align_feature");

my $e1 = Bio::EnsEMBL::Exon->new(
  -start => 10,
  -end => 1000,
  -strand => 1,
  -slice => $slice,
  -phase => 0,
  -end_phase => 0,
  -stable_id => 'ENSE0001',
  -version => 1
);

my $e2 = Bio::EnsEMBL::Exon->new(
  -start => 10,
  -end => 1000,
  -strand => 1,
  -slice => $slice,
  -phase => 0,
  -end_phase => 0,
  -stable_id => 'ENSE0001',
  -version => 2,
  -is_current => 0
);

$exonad->store($e1);
$exonad->store($e2);

$exon = $exonad->fetch_by_stable_id('ENSE0001');
ok( $exon->is_current == 1);

@exons = @{ $exonad->fetch_all_versions_by_stable_id('ENSE0001') };
foreach my $e (@exons) {
  next unless ($e->version == 2);
  ok($e->is_current == 0);
}

$multi->restore();

# TESTS 36-47: Tests for cdna_start(), cdna_end(), cdna_coding_start(),
# cdna_coding_end(), coding_region_start(), and coding_region_end().

my $transcriptad = $db->get_TranscriptAdaptor();
my $transcript   = $transcriptad->fetch_by_stable_id('ENST00000246229');

@exons = @{ $transcript->get_all_Exons() };

$exon = shift @exons;    # First exon is non-coding.

ok( $exon->cdna_start($transcript) == 1 );
ok( $exon->cdna_end($transcript) == 88 );
ok( !defined $exon->cdna_coding_start($transcript) );
ok( !defined $exon->cdna_coding_end($transcript) );
ok( !defined $exon->coding_region_start($transcript) );
ok( !defined $exon->coding_region_end($transcript) );

$exon = shift @exons;    # Second exon is coding.

ok( $exon->cdna_start($transcript) == 89 );
ok( $exon->cdna_end($transcript) == 462 );
ok( $exon->cdna_coding_start($transcript) == 203 );
ok( $exon->cdna_coding_end($transcript) == 462 );
ok( $exon->coding_region_start($transcript) == 30577779 );
ok( $exon->coding_region_end($transcript) == 30578038 );

#test the get_species_and_object_type method from the Registry
my $registry = 'Bio::EnsEMBL::Registry';
my ( $species, $object_type, $db_type ) = $registry->get_species_and_object_type('ENSE00000859937');
ok( $species eq 'homo_sapiens' && $object_type eq 'Exon');
