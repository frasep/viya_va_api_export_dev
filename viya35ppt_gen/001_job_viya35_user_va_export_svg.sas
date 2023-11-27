/*****************************************************************************************************************/
/* Job used by each user to export images generated by his last saved report in the same day                     */

%let USER_ID=&sysuserid; /* Get calling user id */
%let SAVE_ROOTDIR=/tmp/svg_va_tmp; /* Root directory used to create produced files */
%let REFRESH=true; /* specifies whether or not we refresh the report or use cache instead */

/*****************************************************************************************************************/
/* Get the base_uri to make all API calls */
%let BASE_URI = %sysfunc(getoption(servicesbaseurl));
%let BASE_URI = %substr(&BASE_URI, 1, %length(&BASE_URI)-1);

* **************************************************************************************;
* *Get the id of the last report saved by the user specified in parameter **************;
* **************************************************************************************;

FILENAME rptFile TEMP ENCODING='UTF-8';

PROC HTTP METHOD = "GET" oauth_bearer=sas_services OUT = rptFile
      URL = "&BASE_URI/reports/reports?filter=or(eq(modifiedBy,'&USER_ID'),eq(createdBy,'&USER_ID'))&sortBy=modifiedTimeStamp:descending&limit=1";
      HEADERS "Accept" = "application/vnd.sas.collection+json"
               "Accept-Item" = "application/vnd.sas.summary+json";
		debug level=0;
RUN;

LIBNAME rptFile json;

data _null_;
   if 0 then set rptFile.items nobs=n;
   if n=0 then 
   do;
		put "No saved report for user &USER_ID";
		call execute('endsas;');
    end;
   stop;
run;

/* Get only report saved during the current date */
proc sql;
	select count(*) into :n_report trimmed from rptFile.items where input(substr(ModifiedTimeStamp,1,10), yymmdd10.) >= today() ;
quit;

/* Stop if no recent report save occurred */
data _null_;
	if &n_report=0 then 
  	do;
		put "**********************************************************************************";
		put "No saved report today for user &USER_ID";
		put "**********************************************************************************";
		call execute('endsas;');
    end;
	stop;
run;

proc sql noprint;
  select id into :rep_id trimmed from rptFile.items;
quit;

proc sql noprint;
  select name into :REPORT_NAME trimmed from rptFile.items;
quit;

proc sql noprint;
  select ModifiedTimeStamp into :modtime trimmed from rptFile.items;
quit;

* **************************************************************************************;
/* * now get the image,one persection
 * 1. create a job
 * 2. check if finished
 * 3. get the image
 */
* **************************************************************************************;
/* 6.1.
 * create a job to create the image
 * using this API
 * https://developer.sas.com/apis/rest/v3.5/Visualization/#get-report-images-using-request-body
 */
* **************************************************************************************;
/* Example in Viya 3.5
curl -X POST https://example.com/reportImages/jobs#requestBody \
  -H 'Authorization: Bearer <access-token-goes-here>' \
  -H 'Content-Type: application/vnd.sas.report.images.job.request+json' \
  -H 'Accept: application/vnd.sas.report.images.job+json' \
  -H 'Accept-Language: string' \
  -H 'Accept-Locale: string'
*/

filename resp temp;
proc http
  method='POST' 
  url="&BASE_URI/reportImages/jobs"
  oauth_bearer=sas_services
  query =(
	"reportUri" = "/reports/reports/&rep_id"
    "layoutType" = "entireSection" 
    "selectionType" = "perSection" 
    "size" = "1920x1080"
	"refresh" = "&REFRESH"
	"renderLimit" = "-1"
 )
  out=resp
  verbose
  ;
  headers
    "Accept" = "application/vnd.sas.report.images.job+json"
  ;
  debug level=0;
run;
%put NOTE: &=SYS_PROCHTTP_STATUS_CODE;
%put NOTE: &=SYS_PROCHTTP_STATUS_PHRASE;

%put NOTE: response create image job;
%*put %sysfunc( jsonpp(resp, log));

libname resp json;
title "create jobs root";
proc print data=resp.root;
run;

/*
 * get the jobid
 */
proc sql noprint;
  select
    id
  into
    :jobid trimmed
  from
    resp.root
  ;
quit;
%put NOTE: &=jobid;
  
/* 6.2.
 * check if job completed
 * using this API
 * https://developer.sas.com/apis/rest/v3.5/Visualization/#get-the-state-of-the-job
 */
%macro va_img_check_jobstatus(
  jobid=
  , sleep=1
  , maxloop=50
);
%local jobStatus i;

%do i = 1 %to &maxLoop;
  filename jobrc temp;
  proc http
    method='GET' 
    url="&BASE_URI//reportImages/jobs/&jobid/state"
    oauth_bearer=sas_services
  
    out=jobrc
    verbose
    ;
    headers
      "Accept" = "text/plain"
    ;
    debug level=0;
  run;
  %put NOTE: &=SYS_PROCHTTP_STATUS_CODE;
  %put NOTE: &=SYS_PROCHTTP_STATUS_PHRASE;
  
  %put NOTE: response check job status;
  data _null_;
      infile jobrc;
      input line : $32.;
      putlog "NOTE: &sysmacroname jobId=&jobid i=&i status=" line;
      if line in ("completed", "failed") then do;
      end;
      else do;
        putlog "NOTE: &sysmacroname &jobid status=" line "sleep for &sleep.sec";
        rc = sleep(&sleep, 1);
      end;  
      call symputx("jobstatus", line);
  run;
  filename jobrc clear;
  %if &jobstatus = completed %then %do;
    %put NOTE: &sysmacroname &=jobid &=jobStatus;
    %return;
  %end;
  %if &jobstatus = failed %then %do;
    %put ERROR: &sysmacroname &=jobid &=jobStatus;
    %return;
  %end;
%end;
%mend;

%va_img_check_jobstatus(jobid=&jobid, sleep=1, maxloop=500)

/*
 * Get job info
 * using API
 * https://developer.sas.com/apis/rest/v3.5/Visualization/#get-specified-job
 */
filename resp temp;
proc http
  method='GET' 
  url="&BASE_URI/reportImages/jobs/&jobid"
  oauth_bearer=sas_services
  out=resp
  verbose
  ;
  headers
    "Accept" = "application/vnd.sas.report.images.job+json"
    "Content-Type" = "application/vnd.sas.report.images.job.request+json"
  ;
  debug level=0;
run;
%put NOTE: &=SYS_PROCHTTP_STATUS_CODE;
%put NOTE: &=SYS_PROCHTTP_STATUS_PHRASE;

%put NOTE: response create image job;

libname resp json;
title "get report images root";
proc print data=resp.root;
run;
title "get report images links";
proc print data=resp.images_links;
run;
title;

proc sql;
  create table img_info as
  select
    img.*
    , imgl.*
  from
    resp.images as img
    , resp.images_links as imgl
  where
    img.ordinal_images = imgl.ordinal_images
    and method = "GET"
    and rel = "image"
  ;
quit;


/* create directories if necessary */
data _null_;
  rc = dcreate("&USER_ID", "&SAVE_ROOTDIR");
  rc1 = dcreate("&rep_id", "&SAVE_ROOTDIR/&USER_ID");
  rc2 = dcreate("&jobid", "&SAVE_ROOTDIR/&USER_ID/&rep_id");
run;

* ***************************************************************************************;
/* Clean job directory from all previous job outputs */

/* macro deleting a given full filename or empty directory */
%macro dfile(fname=);
	data _null_;
		rc=filename('temp',"&fname");
		if rc=0 and fexist('temp') then rc=fdelete('temp');
		rc=filename('temp');
		put _all_;
	run;
%mend;

/* macro deleting all files in a given directory */
%macro dfolder(dir=);
	data flist;
		rc=filename("mydir","&dir");
		did=dopen("mydir");
		do i = 1 to dnum(did);
	 		fname=dread(did,i);
	 		output;
		end;
		rc=dclose(did);
	run;

	data _null_;
		set flist;
		call execute(cats('%dfile(fname=',"&dir",'/',fname,')'));
	run;
	
%mend;

/* list existing job directories */

data jobdirs;
	rc=filename("mydir","&SAVE_ROOTDIR/&USER_ID/&rep_id");
	did=dopen("mydir");
	n_obs=dnum(did);
	call symput('ndirs',dnum(did));
	if n_obs>=1 then 
	do;
		do i = 1 to n_obs;
	 		dname="&SAVE_ROOTDIR/&USER_ID/&rep_id/" || dread(did,i);
	 		output;
		end;
	end;
	rc=dclose(did);
run;

%macro remove();
   %if &ndirs>=1 %then
      %do;
		data _null_;
			set jobdirs;
			call execute(cats('%dfolder(dir=',dname,')'));
			call execute(cats('%dfile(fname=',dname,')'));
		run;
      %end;
%mend remove;

%remove();

/*
data _null_;
	set jobdirs;
	call execute(cats('%dfolder(dir=',dname,')'));
	call execute(cats('%dfile(fname=',dname,')'));
run;
*/

/* create directories if necessary */
data _null_;
  rc = dcreate("&USER_ID", "&SAVE_ROOTDIR");
  rc = dcreate("&rep_id", "&SAVE_ROOTDIR/&USER_ID");
  rc = dcreate("&jobid", "&SAVE_ROOTDIR/&USER_ID/&rep_id");
run;

* **************************************************************************************;
/* 6.3.
 * macro to get images
 * using API
 * https://developer.sas.com/apis/rest/v3.5/Visualization/#get-image
 */
* **************************************************************************************;
%macro va_report_get_image(
method=get
, imghref=
, outfile=
, type=
, jobid=
);
%put NOTE: &sysmacroname &method &imghref &outfile;

filename img "&SAVE_ROOTDIR/&USER_ID/&rep_id/&jobid/&outfile..svg";
proc http
  method = "&method"
  url = "&BASE_URI/&imghref"
  out=img
  oauth_bearer=sas_services
  verbose
;
  headers
    "Accept" = "&type"
    "Content-Type" = "application/vnd.sas.report.images.job.request+json"
  ;
  debug level=0;
run;
%put NOTE: response get image;
%put NOTE: &=SYS_PROCHTTP_STATUS_CODE;
%put NOTE: &=SYS_PROCHTTP_STATUS_PHRASE;
%mend;

/*
 * build macro calls
 */
filename getimg temp;
data _null_;
  set img_info;
  file getimg;
  length line $ 2048;
  line = cats(
    '%va_report_get_image('
    , cats("method=", method)
    , ","
    , cats("imghref=", href)
    , ","
    , cats("type=", type)
    , ","
    , cats("outfile=", catx("_", ordinal_images, sectionName) )
    , ","
    , "jobid=&jobid"
    , ")"
  );
  put line;
  putlog line;
run;

%inc getimg / source2;

* ***************************************************************************************;
* ***************************************************************************************;
* ***************************************************************************************;
