/* jenner-check bundle: the image_list scan + report/user dedup logic from
 * viya35ppt_gen/using librsvg2-tools/Filesystem based/002_job_viya35_admin_gen_ppt.sas
 *
 * The repo's "MAIN PROGRAM" section scans a filesystem tree of exported
 * .svg files with:
 *   Filename filelist pipe "find &SAVE_ROOTDIR -type f -mmin -60 -name '*.svg'";
 * then parses each path into user/report_id/job_id/ordinal_images columns
 * and deduplicates by (report_id, job_id) and by (report_id, user, job_id).
 * The pipe-based `find` command is substituted here with an inline
 * DATALINES list of the same path shape (checklist item #1/#5) -- the
 * parsing (SCAN/TRANWRD/TRANSLATE), PROC SORT, and first.report_id
 * dedup logic below are copied unmodified from the source script.
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
/tmp/svg_va_tmp/bob/rep_inventory/job_002/1_Overview.svg
/tmp/svg_va_tmp/carol/rep_hr/job_003/1_Overview.svg
/tmp/svg_va_tmp/carol/rep_hr/job_003/2_Attrition.svg
;
run;

proc sort data=image_list;
	by report_id job_id;
run;

/* deduplicate the previous table */
data report_list;
 set image_list;
 by report_id job_id;
 if first.report_id;
 keep report_id job_id;
run;

proc sort data=image_list;
	by report_id user job_id;
run;

/* deduplicate the previous table on user report and job */
data report_user_list_tmp;
 set image_list;
 by report_id user job_id;
 if first.report_id;
 keep report_id user job_id;
run;

title "one row per report/job";
proc print data=report_list;
run;

title "one row per report/user/job";
proc print data=report_user_list_tmp;
run;
title;
