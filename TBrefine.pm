#!/usr/bin/pel

=head1

        TBseq - a computational pipeline for detecting variants in NGS-data

        Copyright (C) 2016 Thomas A. Kohl, Robin Koch, Maria R. De Filippo, Viola Schleusener, Christian Utpatel, Daniela M. Cirillo, Stefan Niemann

        This program is free software: you can redistribute it and/or modify
        it under the terms of the GNU General Public License as published by
        the Free Software Foundation, either version 3 of the License, or
        (at your option) any later version.

        This program is distributed in the hope that it will be useful,
        but WITHOUT ANY WARRANTY; without even the implied warranty of
        MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
        GNU General Public License for more details.

        You should have received a copy of the GNU General Public License
        along with this program.  If not, see <http://www.gnu.org/licenses/>.

=cut

# tabstop is set to 8.

package TBrefine;

use strict;
use warnings;
use File::Copy;
use TBtools;
use Exporter;
use vars qw($VERSION @ISA @EXPORT);

###################################################################################################################
###                                                                                                             ###
### Description: This package use GATK for mapping refinement. It uses realignment around InDels and Base Call	###
### recalibration. In future this step will not be important anymore when switching to the Haplotype caller	###
### for variant detection.										        ###
###                                                                                                             ###
### Input:  .bam                                                                                          	###
### Output: .gatk.bam, .gatk.grp, gatk.intervals, .gatk.bamlog, .bamlog                                         ###
###                                                                                                             ###
###################################################################################################################

$VERSION	=	1.10;
@ISA		=	qw(Exporter);
@EXPORT		=	qw(tbrefine);


sub tbrefine {
	# Get parameter and input from front-end.
	my $logprint		=	shift;
	my $W_dir		=	shift;
	my $VAR_dir		=	shift;
        my $PICARD_dir          =       shift;
	my $IGV_dir             =       shift;
        my $GATK_dir            =       shift;
	my $BAM_OUT		=	shift;
	my $GATK_OUT		=	shift;
	my $ref                 =       shift;
        my $res                 =       shift;
	my $threads		=	shift;
	my @bam_files		=	@_;
	my $input		=	{};
	# Start logic...
	foreach my $file(sort { $a cmp $b } @bam_files) {
		my @file_name		=	split(/_/,$file);
		my $sampleID		=	$file_name[0];
		my $libID		=	$file_name[1];
		my $source		=	$file_name[2];
		my $date		=	$file_name[3];
		my $length		=	$file_name[4];
		$length                 =~      s/(\d+).*$/$1/;
		my $fullID		=	join("_",($sampleID,$libID,$source,$date,$length));
		push(@{$input->{$fullID}},$file);
	}
	foreach my $fullID(sort { $a cmp $b } keys(%$input)) {
		my @bams		=	@{$input->{$fullID}};
		if(scalar(@bams > 1)) {
			print $logprint "<WARN>\t",timer(),"\tSkipping $fullID, more than one file for $fullID!\n";
			next;	
		}
		my @fields		=	split(/_/,$fullID);
		my $sampleID		=	$fields[0];
		my $libID		=	$fields[1];
		my $source		=	$fields[2];
		my $date		=	$fields[3];
		my $length		=	$fields[4];
		print $logprint "<INFO>\t",timer(),"\tUpdating log file for $fullID...\n";
		my $old_logfile		=	$fullID.".bamlog";
		my $merge_logfile	=	$fullID.".mergelog";
		$old_logfile		=	$merge_logfile 	if (-f "$BAM_OUT/$merge_logfile");
		my $logfile		=	$fullID.".gatk.bamlog";
		unlink("$GATK_OUT/$logfile") || print $logprint "<WARN>\t",timer(),"\tCan't delete $logfile: No such file!\n";
		if(-f "$BAM_OUT/$old_logfile") {
			cat($logprint,"$BAM_OUT/$old_logfile","$GATK_OUT/$logfile") || die print $logprint "<ERROR>\t",timer(),"\tcat failed: $!\n";
		}
		my $dict		=	$ref;
		$dict			=~	s/\.fasta/.dict/;
		unlink("$VAR_dir/$dict") || print $logprint "<WARN>\t",timer(),"\tCan't delete $dict: $!\n";
		print $logprint "<INFO>\t",timer(),"\tStart using Picard Tools for creating a dictionary of the reference genome...\n";
		system("java -jar $PICARD_dir/picard.jar CreateSequenceDictionary R=$VAR_dir/$ref O=$VAR_dir/$dict 2>> $GATK_OUT/$logfile");
		print $logprint "<INFO>\t",timer(),"\tFinished using Picard Tools for creating a dictionary of the reference genome!\n";
		# Use RealignerTargetCreator.
		print $logprint "<INFO>\t",timer(),"\tStart using GATK RealignerTargetCreator for $fullID...\n";
		system("java -jar $GATK_dir/GenomeAnalysisTK.jar --analysis_type RealignerTargetCreator --reference_sequence $VAR_dir/$ref --input_file $BAM_OUT/$fullID.bam --downsample_to_coverage 10000 --num_threads $threads --out $GATK_OUT/$fullID.gatk.intervals 2>> $GATK_OUT/$logfile");
		print $logprint "<INFO>\t",timer(),"\tFinished using GATK RealignerTargetCreator for $fullID!\n";
		# Use IndelRealigner.
		print $logprint "<INFO>\t",timer(),"\tStart using GATK IndelRealigner for $fullID...\n";
		system("java -jar $GATK_dir/GenomeAnalysisTK.jar --analysis_type IndelRealigner --reference_sequence $VAR_dir/$ref --input_file $BAM_OUT/$fullID.bam --defaultBaseQualities 12 --targetIntervals $GATK_OUT/$fullID.gatk.intervals --noOriginalAlignmentTags --out $GATK_OUT/$fullID.realigned.bam 2>> $GATK_OUT/$logfile");
		print $logprint "<INFO>\t",timer(),"\tFinished using GATK IndelRealigner for $fullID!\n";
		# If $ref is not h37rv than we skip the next parts.
		unless($ref eq 'M._tuberculosis_H37Rv_2015-11-13.fasta') {
			print $logprint "<INFO>\t",timer(),"\tSkipping GATK BaseRecalibrator! This is only possible with M._tuberculosis_H37Rv_2015-11-13 as reference!\n";
			move("$GATK_OUT/$fullID.realigned.bam","$GATK_OUT/$fullID.gatk.bam") || die print $logprint "<ERROR>\t",timer(),"\tmove failed: $!\n";
			move("$GATK_OUT/$fullID.realigned.bai","$GATK_OUT/$fullID.gatk.bai") || die print $logprint "<ERROR>\t",timer(),"\tmove failed: $!\n";
			next;
		}
		# Index resistance list.
		print $logprint "<INFO>\t",timer(),"\tStart using IGVtools for indexing of $res...\n";
		system("java -jar $IGV_dir/igvtools.jar index $res >> $GATK_OUT/$logfile");
		print $logprint "<INFO>\t",timer(),"\tFinished using IGVtools for indexing of $res!\n";
		# Use BaseRecalibrator.
		print $logprint "<INFO>\t",timer(),"\tStart using GATK BaseRecalibrator for $fullID...\n";
		system("java -jar $GATK_dir/GenomeAnalysisTK.jar --analysis_type BaseRecalibrator --reference_sequence $VAR_dir/$ref --input_file $GATK_OUT/$fullID.realigned.bam --knownSites $res --maximum_cycle_value 600 --num_cpu_threads_per_data_thread $threads --out $GATK_OUT/$fullID.gatk.grp 2>> $GATK_OUT/$logfile");
		print $logprint "<INFO>\t",timer(),"\tFinished using GATK BaseRecalibrator for $fullID!\n";
		# Use print PrintReads.
		print $logprint "<INFO>\t",timer(),"\tStart using GATK PrintReads for $fullID...\n";
		system("java -jar $GATK_dir/GenomeAnalysisTK.jar -T --analysis_type PrintReads --reference_sequence $VAR_dir/$ref --input_file $GATK_OUT/$fullID.realigned.bam --BQSR $GATK_OUT/$fullID.gatk.grp --num_cpu_threads_per_data_thread $threads --out $GATK_OUT/$fullID.gatk.bam  2>> $GATK_OUT/$logfile");
		print $logprint "<INFO>\t",timer(),"\tFinished using GATK PrintReads for $fullID!\n";
		# Index Reference.
		print $logprint "<INFO>\t",timer(),"\tStart using IGVtools for indexing of $ref...\n";
		system("java -jar $IGV_dir/igvtools.jar index $VAR_dir/$ref >> $GATK_OUT/$logfile");
		print $logprint "<INFO>\t",timer(),"\tFinished using IGVtools for indexing of $ref!\n";
		# Removing temporary files.
		print $logprint "<INFO>\t",timer(),"\tRemoving temporary files...\n";
		unlink("$GATK_OUT/$fullID.realigned.bam")	|| print $logprint "<WARN>\t",timer(),"\tCan't delete $fullID.realigned.bam: No such file!\n";
		unlink("$GATK_OUT/$fullID.realigned.bai")	|| print $logprint "<WARN>\t",timer(),"\tCan't delete $fullID.realigned.bai: No such file!\n";
		unlink("$W_dir/igv.log")			|| print $logprint "<WARN>\t",timer(),"\tCan't delete igv.log: No such file!\n";
		# Finished.
		print $logprint "<INFO>\t",timer(),"\tGATK refinement finished for $fullID!\n";
	}
}


1;