#! /usr/bin/env perl
#
# cff-to-opencog.pl
#
# Read in files in the "compact file format", as generated by the
# src/java/relex/output/CompactView.java class, and convert them into 
# opencog format, as generated by src/java/relex/output/OpenCogScheme.java
#
# Usage: "cat somefile | ./cff-to-opencog.pl > otherfile"
#
# Currently includes a cheap hack to ignore files generated by older
# versions of relex (because these are missing inflections, which are
# needed for the stats.)
#
# Copyright (c) 2008 Linas Vepstas <linasvepstas@gmail.com>
#

$min_required_relex_version = "relex-0.11.0";

#--------------------------------------------------------------------
# Need to specify the binmodes, in order for \w to match utf8 chars
use utf8;
binmode STDIN, ':encoding(UTF-8)'; 
binmode STDOUT, ':encoding(UTF-8)';

use UUID;

# print "scm\n";

my $in_sentence = 0;
my $in_parse = 0;
my $in_features = 0;
my $in_links = 0;
my $in_relations = 0;

my $sent_inst = "";
my $parse_inst = "";
my @word_list = ();
my @sent_list = ();
my $uuid;
my $uuidstr;

while (<>)
{
	if (/<parser>/)
	{
		# Compare the file version to the minimum required file version.
		# Any files older than this will fail to generate correct OpenCog
		# output, and so instead, we'll generate no output at all.
		#
		# if(/$required_relex_version/) {}
		/relex-(\d)\.(\d+)\.(\d+)/;
		my $major = $1;
		my $minor = $2;
		my $rev = $3;

		$min_required_relex_version =~ /relex-(\d)\.(\d+)\.(\d+)/;
		my $req_major = $1;
		my $req_minor = $2;
		my $req_rev = $3;

		if ($major < $req_major) { exit 1;}
		if ($minor < $req_minor) { exit 1;}
		if ($rev < $req_rev) { exit 1;}
	}
	if (/<sentence /) { $in_sentence = 1;  next; }
	if (/<features>/) { $in_features = 1; next; }
	if (/<links>/) { $in_links = 1; next; }
	if (/<relations>/) { $in_relations = 1; next; }

	if ($in_sentence)
	{
		$in_sentence = 0;
		chop;
		print "; SENTENCE: [$_]\n";

		UUID::generate($uuid);
		UUID::unparse($uuid, $uuidstr);
		$sent_inst = "sentence@" . $uuidstr;

		push (@sent_list, $sent_inst);
	}
	if (/<parse id="(\d+)">/)
	{
		$in_parse = 1;
		$parse_id = $1;  # matches the \d
		$parse_id -= 1;  # start counting at zero, not 1.

		UUID::generate($uuid);
		UUID::unparse($uuid, $uuidstr);
		$parse_inst = "sentence@" . $uuidstr . "_parse_" . $parse_id;

		print "(ParseLink\n";
		print "\t(ParseNode \"$parse_inst\")\n";
		print "\t(SentenceNode \"$sent_inst\")\n";
		print ")\n";

		# zero out the word list
		@word_list = ();
	}
	if (/<lg-rank num_skipped_words="(\d+)" disjunct_cost="(\d+)" and_cost="(\d+)" link_cost="(\d+)"/)
	{
		my $nsw = $1;
		my $djc = $2;
		my $ac = $3;
		my $lc = $4;
		# This should use the exact same formula as in ParsedSentence.java
		# method simpleRankParse().
		my $rank = 0.4 * $nsw + 0.2 * $djc + 0.06 * $ac + 0.012 * $lc;
		$rank = exp (-$rank);
		if ($rank < 1.0e-3) { $rank = 0.0; }
		print "(ParseNode \"$parse_inst\" (cog-new-stv 1.0 $rank))\n";
	}

	if (/<\/parse>/) { $in_parse = 0; next; }
	if (/<\/links>/) { $in_links = 0; next; }
	if (/<\/relations>/) { $in_relations = 0; next; }

	if (/<\/features>/)
	{
		$in_features = 0;
		# Spew out the sentence
		print "(ReferenceLink\n";
		print "\t(ParseNode \"$parse_inst\")\n";
		print "\t(ListLink\n";
		foreach $word_inst (@word_list)
		{
			print "\t\t(WordInstanceNode \"$word_inst\")\n";
		}
		print "\t)\n";
		print ")\n";

		# Spew links for individual words, too.
		foreach $word_inst (@word_list)
		{
			print "(WordInstanceLink\n";
			print "\t(WordInstanceNode \"$word_inst\")\n";
			print "\t(ParseNode \"$parse_inst\")\n";
			print ")\n";
		}
	}
	if ($in_features)
	{
		($n, $word, $lemma, $pos, $feat) = split;

		# We need to double-escape backslashes; once for scheme, which
		# swallows pairs of them, and once again for SQL, which swallows
		# more pairs. This results with a single backslash in the SQL DB.
		$word =~ s/\\/\\\\\\\\/g;
		$lemma =~ s/\\/\\\\\\\\/g;
		UUID::generate($uuid);
		UUID::unparse($uuid, $uuidstr);
		$word_inst = $word . "@" . $uuidstr;

		push (@word_list, $word_inst);

		print "(ReferenceLink\n";
		print "\t(WordInstanceNode \"$word_inst\")\n";
		print "\t(WordNode \"$word\")\n";
		print ")\n";

		print "(LemmaLink\n";
		print "\t(WordInstanceNode \"$word_inst\")\n";
		print "\t(WordNode \"$lemma\")\n";
		print ")\n";

		print "(PartOfSpeechLink\n";
		print "\t(WordInstanceNode \"$word_inst\")\n";
		print "\t(DefinedLinguisticConceptNode \"$pos\")\n";
		print ")\n";

		@feats = split (/\|/, $feat);
		foreach $f (@feats)
		{
			print "(InheritanceLink\n";
			print "\t(WordInstanceNode \"$word_inst\")\n";
			print "\t(DefinedLinguisticConceptNode \"$f\")\n";
			print ")\n";
		}
	}
	if ($in_links)
	{
		my ($link_type, $left_idx, $right_idx) = /([\w\*]+)\((\d+), (\d+)\)/;

		my $linst = "";
		if (0 == $left_idx) { $linst = "LEFT-WALL"; }
		else { $linst = $word_list[$left_idx-1]; }
		my $rinst = $word_list[$right_idx-1];

		print "(EvaluationLink\n";
		print "\t(LinkGrammarRelationshipNode \"$link_type\")\n";
		print "\t(ListLink\n";
		print "\t\t(WordInstanceNode \"$linst\")\n";
		print "\t\t(WordInstanceNode \"$rinst\")\n";
		print "\t)\n";
		print ")\n";
	}
	if ($in_relations)
	{
		my ($rel_type, $left_idx, $right_idx) = /(\w+\d*)\(\w+\[(\d+)\], \w+\[(\d+)\]\)/;

		my $linst = $word_list[$left_idx-1];
		my $rinst = $word_list[$right_idx-1];

		print "(EvaluationLink\n";
		print "\t(DefinedLinguisticRelationshipNode \"$rel_type\")\n";
		print "\t(ListLink\n";
		print "\t\t(WordInstanceNode \"$linst\")\n";
		print "\t\t(WordInstanceNode \"$rinst\")\n";
		print "\t)\n";
		print ")\n";

	}
}

UUID::generate($uuid);
UUID::unparse($uuid, $uuidstr);
$doc_inst = "document@" . $uuidstr;

# Spew out the document
print "(ReferenceLink\n";
print "\t(DocumentNode \"$doc_inst\")\n";
print "\t(ListLink\n";
foreach $sent_inst (@sent_list)
{
	print "\t\t(SentenceNode \"$sent_inst\")\n";
}
print "\t)\n";
print ")\n";

# Make sure that the opencog input processor finds out 
# about the sentences.
foreach $sent_inst (@sent_list)
{
	print "(ListLink\n";
	print "\t(AnchorNode \"# New Parsed Sentence\")\n";
	print "\t(SentenceNode \"$sent_inst\")\n";
	print ")\n";
}

# print ".\n";
# print "exit\n";
