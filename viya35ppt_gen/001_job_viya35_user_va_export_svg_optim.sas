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
		put "No saved report for user &USER_ID during the current day.";
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
    id into :jobid trimmed
  from
    resp.root;
quit;

proc sql noprint;
  select
    creationTimeStamp into :jobtime
  from
    resp.root
  ;
quit;

%put NOTE: &=jobtime;
%put NOTE: &=jobid;

libname jobref base "&SAVE_ROOTDIR";

/* Add job with characterisitcs to the job_ref file */
data jobref.job_ref;
  	length report_id $ 50 user_id $ 128 job_id $ 50;
	report_id = "&rep_id";
  	user_id="&user_id";
  	job_id="&jobid";
	jobdt=input(substr("$jobtime",1,23), YMDDTTM23.);
run;

* ***************************************************************************************;
* ***************************************************************************************;
* ***************************************************************************************;
