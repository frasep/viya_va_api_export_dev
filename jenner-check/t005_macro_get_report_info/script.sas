/* jenner-check bundle: get_report_info() macro from
 * viya35ppt_gen/using librsvg2-tools/Filesystem based/002_job_viya35_admin_gen_ppt.sas
 *
 * get_report_info() normally does a PROC HTTP GET against
 * &BASE_URI/reports/reports/&repid, parses the JSON response via
 * "libname resp json;", keeps report_id/name, then accumulates results
 * across many report ids via PROC APPEND into report_list_full -- the
 * exact loop the repo's admin job runs once per distinct report found
 * on disk.
 *
 * Substituted per the mandatory checklist: the PROC HTTP call is
 * replaced with a small JSON payload written inline by the script
 * itself (checklist item #1 -- external libname/REST call -> local
 * mock data), one per report id, mirroring what a captured HTTP
 * response would contain. The macro's JSON-parsing + KEEP + PROC
 * APPEND body is copied unmodified.
 */

%macro get_report_info(repid, jsonfile, libref, outds=report_list_full);
	libname &libref json fileref=&jsonfile;

	data report_list_tmp;
		set &libref..root;
		report_id = id;
		keep report_id name;
	run;

	proc append base=&outds data=report_list_tmp force;
	run;
%mend get_report_info;

/* Mock captured HTTP responses, written inline so the bundle is
 * self-contained (no sibling data file required). */
filename rep1js "rep1.json";
data _null_;
  file rep1js;
  put '{"id":"rep_sales_001","name":"Sales_Report"}';
run;

filename rep2js "rep2.json";
data _null_;
  file rep2js;
  put '{"id":"rep_inventory_002","name":"Inventory_Report"}';
run;

filename rep3js "rep3.json";
data _null_;
  file rep3js;
  put '{"id":"rep_hr_003","name":"HR_Attrition_Report"}';
run;

proc datasets nodetails nolist nowarn;
	delete report_list_full;
run;

/* A distinct libref per call, rather than reassigning one shared "resp"
 * libref three times, sidesteps a JSON-libname-engine limitation where
 * reassigning an already-used libref to a different file does not pick
 * up the new file's content -- the source macro's own JSON-parsing +
 * KEEP + PROC APPEND accumulation logic is otherwise unchanged. */
%get_report_info(rep_sales, rep1js, libref=r1)
%get_report_info(rep_inventory, rep2js, libref=r2)
%get_report_info(rep_hr, rep3js, libref=r3)

proc print data=report_list_full;
  title "reports resolved via get_report_info()";
run;
title;
