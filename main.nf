#!/usr/bin/env nextflow
/*
========================================================================================
                         qbicsoftware/rnadeseq
========================================================================================
 qbicsoftware/rnadeseq Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/qbicsoftware/rnadeseq
----------------------------------------------------------------------------------------
*/


def helpMessage() {
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run qbicsoftware/rnadeseq --rawcounts 'counts.tsv' --metadata 'metadata.tsv' --design 'design.txt' --contrasts 'contrasts.tsv' -profile docker

    Mandatory arguments when producing a report:
      --rawcounts                   Raw count table (TSV). Columns are samples and rows are genes. 1st column Ensembl_ID, 2nd column gene_name.
      --metadata                    Metadata table (TSV). Rows are samples and columns contain sample grouping.
      --model                       Linear model function to calculate the contrasts (TXT). Variable names should be columns in metadata file.
      --contrasts                   Table indicating which contrasts to consider. 1 or 0 for every variable specified in the design. If not provided, default DESeq2 contrasts are calculated.
      --species                     Species name. Format example: Hsapiens.
      --project_summary             Project summary file downloaded from the qPortal.
      --multiqc                     multiqc.zip folder containing the multiQC plots and report.
      --versions                    Software_versions.csv generated by the RNAseq pipeline.
      --quote                       Signed copy of the offer.
      --report_options              Configuration file containing the section to be present in the report. Also contains any line to be added to the outlook.
      -profile                      Configuration profile to use. Can use multiple (comma separated)
                                    Available: conda, docker, singularity, awsbatch, test and more.

    When not aiming for a report:
      --NoReportNeeded              When this is specified, all arguments are optional and analysis steps are run depending on specified input paths.

    For bacteria communities (metagenome or metatranscriptome)
      --humann_reads                Pre-processed reads (e.g. from nf-core/rnaseq with parameters --remove_rRNA & --save_nonrRNA_reads)
      --humann_nucleotide_db        (default: internal uniref_DEMO database)
      --humann_protein_db           Diamond dabase (default: internal chocophlan_DEMO database)
      --humann_metaphlan2_db        MetaPhlAn2 database (default: "https://bitbucket.org/biobakery/metaphlan2/downloads/mpa_v20_m200.tar")

    Options:
      --logFCthreshold              Threshold (int) to apply to Log 2 Fold Change to consider a gene as differentially expressed.
      --genelist                    List of genes (one per line) of which to plot heatmaps for normalized counts across all samples.                
      --fastqc                      zip file containing the fastqc reports.

    Other options:
      --outdir                      The output directory where the results will be saved
      --email                       Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --maxMultiqcEmailFileSize     Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name                         Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.

    AWSBatch options:
      --awsqueue                    The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion                   The AWS Region for your AWS Batch job to run on
    """.stripIndent()
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Show help emssage
if (params.help){
    helpMessage()
    exit 0
}

// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if( !(workflow.runName ==~ /[a-z]+_[a-z]+/) ){
  custom_runName = workflow.runName
}


if( workflow.profile == 'awsbatch') {
  // AWSBatch sanity checking
  if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
  // Check outdir paths to be S3 buckets if running on AWSBatch
  // related: https://github.com/nextflow-io/nextflow/issues/813
  if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
  // Prevent trace files to be stored on S3 since S3 does not support rolling files.
  if (workflow.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Stage config files
ch_multiqc_config = Channel.fromPath(params.multiqc_config)
ch_output_docs = Channel.fromPath("$baseDir/docs/output.md")

/*
 * Create a channel for input  files
 */
//Check that all input files are given in case that a report is needed
params.NoReportNeeded = false
if (!params.NoReportNeeded) {
    if (!params.rawcounts || !params.metadata || !params.quote || !params.model || !params.project_summary || !params.versions || !params.report_options || !params.multiqc || !params.species ) {
      if (!params.rawcounts) { log.info"Please provide raw counts file!"} 
      if (!params.metadata) { log.info "Please provide metadata file!"}
      if (!params.quote) { log.infog"Please provide a PDF of the signed quote!"}
      if (!params.model) { log.info"Please provide linear model file!"}
      if (!params.project_summary) { log.info"Please provide project summary file!"}
      if (!params.versions) {log.info"Please provide sofware versions file!"}
      if (!params.report_options) {log.info"Please provide report options file!"}
      if (!params.multiqc) {log.info"Please provide multiqc.zip folder!"}
      if (!params.species) {log.info"Please provide species name!"}
      exit 1, "If you need a report, please provide all parameters! Otherwise use '--NoReportNeeded'"
    }
}

//Return empty channel for unspecified parameters or check that specified paths exist
if (params.rawcounts) {
  Channel.fromPath("${params.rawcounts}", checkIfExists: true)
            .ifEmpty{exit 1, "Please provide a valid path to raw counts file!"}
            .set {ch_counts_file}
} else { Channel.from().set {ch_counts_file} }

if (params.metadata) {
  Channel.fromPath("${params.metadata}", checkIfExists: true)
            .ifEmpty{exit 1, "Please provide a valid path to metadata file!"}
            .into { ch_metadata_file_for_deseq2; ch_metadata_file_for_pathway }
} else { Channel.from().into{ ch_metadata_file_for_deseq2; ch_metadata_file_for_pathway } }

if (params.quote) {
  Channel.fromPath("${params.quote}", checkIfExists: true)
            .ifEmpty{exit 1, "Please provide a valid path to a PDF of the signed quote!"}
            .set { ch_quote_file}
} else { Channel.from().set {ch_quote_file} }

if (params.model) {
  Channel.fromPath("${params.model}", checkIfExists: true)
              .ifEmpty{exit 1, "Please provide a valid path to linear model file!"}
              .into { ch_model_for_deseq2_file; ch_model_for_report_file; ch_model_file_for_pathway}
} else { Channel.from().into { ch_model_for_deseq2_file; ch_model_for_report_file; ch_model_file_for_pathway} }

if (params.project_summary) {
  Channel.fromPath("${params.project_summary}", checkIfExists: true)
              .ifEmpty{exit 1, "Please provide a valid path to project summary file!"}
              .set { ch_proj_summary_file }
} else { Channel.from().set {ch_proj_summary_file} }

if (params.versions) {
  Channel.fromPath("${params.versions}", checkIfExists: true)
              .ifEmpty{exit 1, "Please provide a valid path to sofware versions file!"}
              .set { ch_softwareversions_file }
} else { Channel.from().set {ch_softwareversions_file} }

if (params.report_options) {
  Channel.fromPath("${params.report_options}", checkIfExists: true)
              .ifEmpty{exit 1, "Please provide a valid path to report options file!"}
              .set { ch_report_options_file }
} else { Channel.from().set {ch_report_options_file} }

if (params.multiqc) {
  Channel.fromPath("${params.multiqc}", checkIfExists: true)
              .ifEmpty{exit 1, "Please provide a valid path to multiqc.zip folder!"}
              .set { ch_multiqc_file }
} else { Channel.from().set {ch_multiqc_file} }

if (params.contrasts) {
  if ("${params.contrasts}"=="DEFAULT") { 
    Channel.fromPath("${params.contrasts}")
                .into { ch_contrasts_for_deseq2_file; ch_contrasts_for_report_file }
  } else {
    Channel.fromPath("${params.contrasts}", checkIfExists: true)
                .ifEmpty{exit 1, "Please provide contrast file!"}
                .into { ch_contrasts_for_deseq2_file; ch_contrasts_for_report_file }
  }
} else { Channel.from().into { ch_contrasts_for_deseq2_file; ch_contrasts_for_report_file } }

if (params.genelist) {
  if ("${params.genelist}"=="NO_FILE") { 
    Channel.fromPath("${params.genelist}")
                .into { ch_genes_for_deseq2_file; ch_genes_for_report_file }
  } else {
    Channel.fromPath("${params.genelist}", checkIfExists: true)
                .ifEmpty{exit 1, "Please provide a valid path to a gene list file!"}
                .into { ch_genes_for_deseq2_file; ch_genes_for_report_file }
  }
} else { Channel.from().into { ch_genes_for_deseq2_file; ch_genes_for_report_file } }

if (params.fastqc) {
  if ("${params.fastqc}"=="NO_FILE") { 
    Channel.fromPath("${params.fastqc}")
                .set { ch_fastqc_file }
  } else {
    Channel.fromPath("${params.fastqc}", checkIfExists: true)
                .ifEmpty{exit 1, "Please provide a valid path to FastQC report!"}
                .set { ch_fastqc_file }
  }
} else { Channel.from().set { ch_fastqc_file } }

Channel.fromPath("${params.humann_nucleotide_db}")
          .ifEmpty{exit 1, "Please provide a valid path to a folder containing the chocophlan database!"}
          .set { ch_humann_nucdb }

Channel.fromPath("${params.humann_protein_db}")
          .ifEmpty{exit 1, "Please provide a valid path to a folder containing a uniref_90 database!"}
          .set { ch_humann_protdb }

//TODO: remove the default below!
//params.humann_reads = "https://bitbucket.org/biobakery/biobakery/raw/tip/demos/biobakery_demos/data/humann2/input/demo.fastq"

//Channel for preprocessed reads for HUMAnN2
if(params.readPaths){
    if(params.singleEnd){
        Channel
            .from(params.readPaths)
            .map { row -> [ row[0], [file(row[1][0])]] }
            .ifEmpty { exit 1, "params.readPaths was empty - no input files supplied" }
            .set { ch_processed_reads }
    } else {
        Channel
            .from(params.readPaths)
            .map { row -> [ row[0], [file(row[1][0]), file(row[1][1])]] }
            .ifEmpty { exit 1, "params.readPaths was empty - no input files supplied" }
            .set { ch_processed_reads }
    }
} else {
  if (params.humann_reads) {
    Channel
        .fromFilePairs( params.humann_reads, size: params.singleEnd ? 1 : 2 )
        .ifEmpty { exit 1, "Cannot find any reads matching: ${params.humann_reads}\nNB: Path needs to be enclosed in quotes!\nNB: Path requires at least one * wildcard!\nIf this is single-end data, please specify --singleEnd on the command line." }
        .set { ch_processed_reads }
  } else { Channel.from().set { ch_processed_reads } }
}

Channel.fromPath("${params.humann_metaphlan2_db}")
          .ifEmpty{exit 1, "Please provide a valid path to a MetaPhlAn2 file (.tar)!"}
          .set { ch_humann_metaphlan2_db }

/*
 * Check mandatory parameters
 */
//All input parameters are optional right now, when --NoReportNeeded
//TODO: log.info warnings when specific processes are not executed because of limited input.


// Header log info
log.info nfcoreHeader()
def summary = [:]
if(workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
summary['Gene Counts'] = params.rawcounts
summary['Metadata'] = params.metadata
summary['Model'] = params.model
summary['Contrasts'] = params.contrasts
summary['Gene list'] = params.genelist
summary['Project summary'] = params.project_summary
summary['nf-core/rnaseq versions'] = params.versions
summary['Report options file'] = params.report_options
summary['Fastqc reports'] = params.fastqc
summary['Multiqc results'] = params.multiqc
summary['Species'] = params.species
summary['Quote'] = params.quote
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if(workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if(workflow.profile == 'awsbatch'){
   summary['AWS Region']    = params.awsregion
   summary['AWS Queue']     = params.awsqueue
}
summary['Config Profile'] = workflow.profile
if(params.config_profile_description) summary['Config Description'] = params.config_profile_description
if(params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if(params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if(params.email) {
  summary['E-mail Address']  = params.email
  summary['MultiQC maxsize'] = params.maxMultiqcEmailFileSize
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "\033[2m----------------------------------------------------\033[0m"

// Check the hostnames against configured profiles
checkHostname()

def create_workflow_summary(summary) {
    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'qbicsoftware-rnadeseq-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'qbicsoftware/rnadeseq Workflow Summary'
    section_href: 'https://github.com/qbicsoftware/rnadeseq'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </dl>
    """.stripIndent()

   return yaml_file
}


/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy',
    saveAs: {filename ->
        if (filename.indexOf(".csv") > 0) filename
        else null
    }

    output:
    file 'software_versions_mqc.yaml' into software_versions_yaml
    file "software_versions.tsv"

    script:
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    echo \$(R --version 2>&1) > v_R.txt
    Rscript -e "library(RColorBrewer); write(x=as.character(packageVersion('RColorBrewer')), file='v_rcolorbrewer.txt')"
    Rscript -e "library(reshape2); write(x=as.character(packageVersion('reshape2')), file='v_reshape2.txt')"
    Rscript -e "library(genefilter); write(x=as.character(packageVersion('genefilter')), file='v_genefilter.txt')"
    Rscript -e "library(DESeq2); write(x=as.character(packageVersion('DESeq2')), file='v_deseq2.txt')"
    Rscript -e "library(ggplot2); write(x=as.character(packageVersion('ggplot2')), file='v_ggplot2.txt')"
    Rscript -e "library(plyr); write(x=as.character(packageVersion('plyr')), file='v_plyr.txt')"
    Rscript -e "library(vsn); write(x=as.character(packageVersion('vsn')), file='v_vsn.txt')"
    Rscript -e "library(gplots); write(x=as.character(packageVersion('gplots')), file='v_gplots.txt')"
    Rscript -e "library(pheatmap); write(x=as.character(packageVersion('pheatmap')), file='v_pheatmap.txt')" 
    Rscript -e "library(optparse); write(x=as.character(packageVersion('optparse')), file='v_optparse.txt')"
    Rscript -e "library(svglite); write(x=as.character(packageVersion('svglite')), file='v_svglite.txt')"
    humann2 --version > v_humann2.txt
    bowtie2 --version > v_bowtie2.txt
    diamond --version > v_diamond.txt
    metaphlan2.py -v > v_metaphlan2.txt
    Rscript -e "library(Maaslin2); write(x=as.character(packageVersion('Maaslin2')), file='v_maaslin2.txt')"
    python --version > v_python.txt
    ktImportText > v_kronatools.txt
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}

/*
 * STEP 1 - DE analysis
 */
process DESeq2 {
    publishDir "${params.outdir}/DESeq2", mode: 'copy'

    input:
    file(gene_counts) from ch_counts_file
    file(metadata) from ch_metadata_file_for_deseq2
    file(model) from ch_model_for_deseq2_file
    file(contrasts) from ch_contrasts_for_deseq2_file
    file(genelist) from ch_genes_for_deseq2_file

    output:
    file "*.zip" into ch_deseq2_for_report, ch_deseq2_for_pathway
    file "contrast_names.txt" into ch_contrnames_for_report

    script:
    def genelistopt = genelist.name != 'NO_FILE' ? "--genelist $genelist" : ''
    def contrastsopt = contrasts.name != 'DEFAULT' ? "--contrasts $contrasts" : ''
    """
    DESeq.v2.7.R --counts $gene_counts --metadata $metadata --design $model --logFCthreshold $params.logFCthreshold $contrastsopt $genelistopt
    zip -r DESeq2.zip DESeq2
    """
}

/*
 * STEP 2 - Pathway analysis
 */

process Pathway_analysis {
    publishDir "${params.outdir}/pathway_analysis", mode: 'copy'

    input:
    file(deseq_output) from ch_deseq2_for_pathway
    file(metadata) from ch_metadata_file_for_pathway
    file(model) from ch_model_file_for_pathway

    output:
    file "*.zip" into ch_gprofiler_for_report

    script:
    """
    unzip $deseq_output
    gProfileR.R --dirContrasts 'DESeq2/DE_genes_tables/' --metadata $metadata \
    --model $model --normCounts 'DESeq2/gene_counts_tables/rlog_transformed_gene_counts.tsv' \
    --species $params.species
    zip -r gProfileR.zip gProfileR/
    """
}

/*
 * STEP 2.1 - Pathway analysis with HUMAnN2
 */

process bowtie_db {
    tag "${tar_db.baseName}"

    input:
    file(tar_db) from ch_humann_metaphlan2_db

    output:
    set val("${tar_db.baseName}"), file("${tar_db.baseName}*") into ch_humann_bowtie_db

    script:
    """
    tar -xvf ${tar_db}
    bzip2 -dk ${tar_db.baseName}.fna.bz2
    bowtie2-build -f ${tar_db.baseName}.fna ${tar_db.baseName}
    """
}

process humann {
    tag "${name}"
    //publishDir "${params.outdir}/pathway_analysis", mode: 'copy'

    input:
    set val(name), file(reads), file(NUCDB), file(PROTDB), val(db_name), file("bowtie_db/*") from ch_processed_reads.combine(ch_humann_nucdb).combine(ch_humann_protdb).combine(ch_humann_bowtie_db)

    output:
    file "outfolder/*" into ch_humann_all
    set val("${reads[0].name}"), file("outfolder/**metaphlan_bugs_list.tsv") into ch_humann_buglist

    script:
    def command_merge = params.singleEnd ? '' : "cat $reads > $name.fastq.gz"
    """
    ${command_merge}
    humann2 \
      --metaphlan-options "-t rel_ab --bowtie2db ./bowtie_db" \
      --threads ${task.cpus} \
      -i $reads \
      -o outfolder \
      --nucleotide-database $NUCDB \
      --protein-database $PROTDB \
      --gap-fill on \
      --verbose
    """
}

process humann_merge {
    publishDir "${params.outdir}/pathway_analysis_humann", mode: 'copy'

    input:
    file("all/*") from ch_humann_all.collect()

    output:
    file "*.tsv"

    script:
    """
    humann2_join_tables \
      --input all \
      --output humann2_genefamilies.tsv \
      --file_name genefamilies
    humann2_join_tables \
      --input all \
      --output humann2_pathcoverage.tsv \
      --file_name pathcoverage
    humann2_join_tables \
      --input all \
      --output humann2_pathabundance.tsv \
      --file_name pathabundance
    """
}

process buglist_to_krona {
    input:
    set val(bug), file("krona") from ch_humann_buglist

    output:
    file "*.krona" into ch_humann_krona

    script:
    """
    metaphlan2krona.py -p krona -k ${bug}.krona
    """
}

process krona {
    publishDir "${params.outdir}/pathway_analysis_humann", mode: 'copy'

    input:
    file(krona) from ch_humann_krona.collect()

    output:
    file "taxonomy.krona.html"

    script:
    """
    ktImportText -o taxonomy.krona.html $krona
    """
}

/*
 * STEP 3 - RNAseq Report
 */
process Report {
    publishDir "${params.outdir}/report", mode: 'copy'

    input:
    file(proj_summary) from ch_proj_summary_file
    file(softwareversions) from ch_softwareversions_file
    file(model) from ch_model_for_report_file
    file(report_options) from ch_report_options_file
    file(contrnames) from ch_contrnames_for_report
    file(fastqc) from ch_fastqc_file
    file(deseq2) from ch_deseq2_for_report
    file(multiqc) from ch_multiqc_file
    file(genelist) from ch_genes_for_report_file
    file(gprofiler) from ch_gprofiler_for_report
    file(quote) from ch_quote_file

    output:
    file "*.zip"
    file "RNAseq_report.html" into rnaseq_report

    script:
    def genelistopt = genelist.name != 'NO_FILE' ? "--genelist $genelist" : ''
    def fastqcopt = fastqc.name != 'NO_FILE' ? "$fastqc" : ''
    """
    unzip $deseq2
    unzip $multiqc
    unzip $gprofiler
    mkdir QC
    mv MultiQC/multiqc_plots/ MultiQC/multiqc_data/ MultiQC/multiqc_report.html $fastqcopt QC/
    Execute_report.R --report '$baseDir/assets/RNAseq_report.Rmd' --output 'RNAseq_report.html' --proj_summary $proj_summary \
    --versions $softwareversions --model $model --report_options $report_options --contrasts $contrnames $genelistopt --quote $quote
    mv qc_summary.tsv QC/
    zip -r report.zip RNAseq_report.html DESeq2/ QC/ gProfileR/ $quote
    """
}


/*
 * STEP 4 - Output Description HTML
 */
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    input:
    file output_docs from ch_output_docs

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.r $output_docs results_description.html
    """
}



/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[qbicsoftware/rnadeseq] Successful: $workflow.runName"
    if(!workflow.success){
      subject = "[qbicsoftware/rnadeseq] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if(workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if(workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if(workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    if(workflow.container) email_fields['summary']['Docker image'] = workflow.container
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // On success try attach the RNAseq report ot the email
    def qbic_report = null
    try {
        if (workflow.success) {
            qbic_report = rnaseq_report.getVal()
            if (qbic_report.getClass() == ArrayList){
                log.warn "[qbicsoftware/rnadeseq] Found multiple reports from process 'RNAseq report', will use only one"
                qbic_report = qbic_report[0]
            }
        }
    } catch (all) {
        log.warn "[qbicsoftware/rnadeseq] Could not attach RNAseq report to summary email"
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: params.email, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: qbic_report, mqcMaxSize: params.maxMultiqcEmailFileSize.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (params.email) {
        try {
          if( params.plaintext_email ){ throw GroovyException('Send plaintext e-mail, not HTML') }
          // Try to send HTML e-mail using sendmail
          [ 'sendmail', '-t' ].execute() << sendmail_html
          log.info "[qbicsoftware/rnadeseq] Sent summary e-mail to $params.email (sendmail)"
        } catch (all) {
          // Catch failures and try with plaintext
          [ 'mail', '-s', subject, params.email ].execute() << email_txt
          log.info "[qbicsoftware/rnadeseq] Sent summary e-mail to $params.email (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File( "${params.outdir}/pipeline_info/" )
    if( !output_d.exists() ) {
      output_d.mkdirs()
    }
    def output_hf = new File( output_d, "pipeline_report.html" )
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File( output_d, "pipeline_report.txt" )
    output_tf.withWriter { w -> w << email_txt }

    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";

    if (workflow.stats.ignoredCountFmt > 0 && workflow.success) {
      log.info "${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}"
      log.info "${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCountFmt} ${c_reset}"
      log.info "${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCountFmt} ${c_reset}"
    }

    if(workflow.success){
        log.info "${c_purple}[qbicsoftware/rnadeseq]${c_green} Pipeline completed successfully${c_reset}"
    } else {
        checkHostname()
        log.info "${c_purple}[qbicsoftware/rnadeseq]${c_red} Pipeline completed with errors${c_reset}"
    }

}


def nfcoreHeader(){
    // Log colors ANSI codes
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";

    return """    ${c_dim}----------------------------------------------------${c_reset}
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  qbicsoftware/rnadeseq v${workflow.manifest.version}${c_reset}
    ${c_dim}----------------------------------------------------${c_reset}
    """.stripIndent()
}

def checkHostname(){
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if(params.hostnames){
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if(hostname.contains(hname) && !workflow.profile.contains(prof)){
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
