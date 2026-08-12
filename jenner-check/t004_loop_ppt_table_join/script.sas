/* jenner-check bundle: the loop_ppt_table join from
 * viya35ppt_gen/using librsvg2-tools/Filesystem based/002_job_viya35_admin_gen_ppt.sas
 *
 * The repo joins the on-disk image_list (svg files found per job) against
 * img_info (per-image section labels, normally fetched from the SAS Viya
 * REST API and parsed via a JSON libname) to build the per-slide worklist
 * that drives generate_ppt_file()'s %inc-generated %print_images() calls:
 *
 *   proc sql;
 *     create table loop_ppt_table as
 *     select A.user, A.report_id, A.filename, A.image_filename, A.job_id,
 *            B.sectionLabel, B.ordinal_images
 *     from WORK.IMAGE_LIST as A, WORK.IMG_INFO as B
 *     where A.job_id=B.job_id and A.ordinal_images=B.ordinal_images;
 *   quit;
 *
 * Copied unmodified below. img_info (normally REST/JSON-derived) is
 * substituted with a small inline DATALINES table of the same shape
 * (checklist item #1) so the join and PROC SORT can run against real
 * data instead of a live SAS Viya server.
 */

data image_list;
  length filename $512 user $50 report_id $50 job_id $50 image_filename $200;
  input filename $char100.;
  user=scan(filename,3,'/');
  report_id=scan(filename,4,'/');
  job_id=scan(filename,5,'/');
  ordinal_images=input(scan(scan(filename,6,'/'),1,"_"),best.);
  image_filename=translate(tranwrd(filename, "/tmp/svg_va_tmp/", ""), "_", "/");
  datalines;
/tmp/svg_va_tmp/alice/rep_sales/job_001/1_Overview.svg
/tmp/svg_va_tmp/alice/rep_sales/job_001/2_Regional.svg
;
run;

/* mock of img_info, normally built by %get_report_job_info() against
   resp.images (a JSON-libname-parsed SAS Viya REST response) */
data img_info;
  length job_id $50 sectionLabel $50;
  input job_id $ ordinal_images sectionLabel $;
  datalines;
job_001 1 Overview
job_001 2 Regional
;
run;

proc sql;
	create table loop_ppt_table as
	select A.user, A.report_id, A.filename, A.image_filename, A.job_id, B.sectionLabel, B.ordinal_images
	from WORK.IMAGE_LIST as A, WORK.IMG_INFO as B
	where A.job_id=B.job_id and A.ordinal_images=B.ordinal_images;
quit;

proc sort data=loop_ppt_table;
	by user report_id ordinal_images;
run;

proc print data=loop_ppt_table;
run;
