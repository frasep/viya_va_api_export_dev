/* Parameter with report full name */

%let REPORT_NAME=test_rapport_casuser;

%let SAVE_ROOTDIR=~; /* Root directory used to create produced files */
%let REFRESH=false; /* specifies whether or not we refresh the report or use cache instead */
/*
 * Get the base_uri to make all API calls
 */
%let BASE_URI = %sysfunc(getoption(servicesbaseurl));
%let BASE_URI = %substr(&BASE_URI, 1, %length(&BASE_URI)-1);
%put NOTE: &=BASE_URI;

* **************************************************************************************;
* *Get the id of the report based on report name **************************************;
* **************************************************************************************;

FILENAME rptFile TEMP ENCODING='UTF-8';

PROC HTTP METHOD = "GET" oauth_bearer=sas_services OUT = rptFile
      URL = "&BASE_URI/reports/reports?filter=eq(name,'&REPORT_NAME')";
      HEADERS "Accept" = "application/vnd.sas.collection+json"
               "Accept-Item" = "application/vnd.sas.summary+json";
RUN;

LIBNAME rptFile json;

proc sql noprint;
  select id into :rep_id trimmed from rptFile.items;
quit;

%put &rep_id;

* **************************************************************************************;
* *Get the id of the report state based on report name (only for the user requesting it) 
* **************************************************************************************;
/* NOTE : Report state is saved when exiting the report in viewer mode */

FILENAME rptFile TEMP ENCODING='UTF-8';

PROC HTTP METHOD = "GET" oauth_bearer=sas_services OUT = rptFile
      URL = "&BASE_URI/reports/reports/&rep_id/states";
      HEADERS "Accept" = "application/vnd.sas.collection+json"
               "Accept-Language" = "string";
RUN;

LIBNAME rptFile json;
proc sql noprint;
  select id into :state_id trimmed from rptFile.items;
quit;

%put &state_id;


* **************************************************************************************;
* *Get the content of the report state based on report name (only for the user requesting it) 
* **************************************************************************************;
FILENAME repJson "/home/frasep/reportContent.json" ENCODING='UTF-8' ;

PROC HTTP METHOD = "GET" oauth_bearer=sas_services OUT = repJson
      URL = "&BASE_URI/reports/reports/&rep_id/states/&state_id/content";
      HEADERS
		"Accept" = "application/vnd.sas.report.content+json";
	debug level=0;
RUN;

libname repJson json;

proc sql noprint;
  create table list_datasrc as select distinct server,library,table from repJson.DATASOURCES_CASRESOURCE;
quit;

FILENAME json_in "/home/frasep/reportContentTransform.json" ENCODING='UTF-8' ;

data _null_;
	file json_in;
	put '{'/
	  '"resultReportName" : "Temp_report",'/
	  '"resultReport": {'/
      '		"name": "Temp_report",'/
      '		"description": "TEST report transform"'/
      '},'/
	  '"dataSources": [';
run;



data _null_;
	set list_datasrc;
	file json_in mod;

	put '{'/
		'"namePattern": "serverLibraryTable",'/
    	'"purpose": "original",';
	line=cats('"server": "', server,'",');
    put line;
    put	'"library": "CASUSER",';
	line=cats('"table": "',table,'"');
	put line;
    put	' },'/
      	' {'/
	  	'"namePattern": "serverLibraryTable",'/
      	'"purpose": "replacement",';
	line=cats('"server": "',server,'",');
	put line;
	line=cats('"library": "CASUSER(', "&sysuserid",')",');
	put line;
    line=cats('"table": "',table,'"');  	
    put line;
    put  '}';
	if _n_ <n then put ',';
run;

data _null_;
	file json_in mod;
	put '],'/
	'"reportContent": ';
run;

data _null_;
    infile repJson;
	file json_in mod;
	input;
	put _infile_;
run;

data _null_;
	file json_in mod;
	put  '}';
run;


%let REST_QUERY_URI=&BASE_URI/reportTransforms/dataMappedReports?validate=false%str(&)saveResult=true;

FILENAME repFinal "/home/frasep/reportContentFinal.json" ENCODING='UTF-8' ;

PROC HTTP METHOD = "POST" oauth_bearer=sas_services OUT = repFinal IN = json_in
      URL = "&REST_QUERY_URI";
      HEADERS 
		"Accept" = "application/vnd.sas.report.transform+json" 
        "Content-Type" = "application/vnd.sas.report.transform+json";
		debug level=0;
RUN;

LIBNAME repFinal json;

proc sql noprint;
  select resultReportName into :rtmp_id trimmed from repFinal.root;
quit;

%put &rtmp_id;

* **************************************************************************************;
* * Generate images for a given report state 
* **************************************************************************************;

filename resp temp;
proc http
  method='POST' 
  url="&BASE_URI/reportImages/jobs"
  oauth_bearer=sas_services
  query =(
	"reportUri" = "/reports/reports/&rtmp_id"
    "layoutType" = "entireSection" 
    "selectionType" = "perSection" 
    "size" = "1920x1080"
	"refresh" = "true"
 )
  out=resp
  verbose
  ;
  headers
    "Accept" = "application/vnd.sas.report.images.job+json"
  ;
  debug level=3;
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
 * https://developer.sas.com/apis/rest/Visualization/#get-specified-job
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
%*put %sysfunc( jsonpp(resp, log));

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

* **************************************************************************************;
/* 6.3.
 * macro to get images
 * using API
 * https://developer.sas.com/apis/rest/Visualization/#get-image
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

data _null_;
  rc = dcreate("&jobid", "&SAVE_ROOTDIR");
run;
filename img "~/&jobid/&outfile..svg";
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
    , cats("outfile=", catx("_", ordinal_images, sectionName, elementName,  visualType) )
    , ","
    , "jobid=&jobid"
    , ")"
  );
  put line;
  putlog line;
run;

%inc getimg / source2;

filename resp temp;
proc http
  method='DELETE' 
  url="&BASE_URI/reports/reports/&rtmp_id"
  oauth_bearer=sas_services
  out=resp
  verbose
  ;
  headers
    "Accept" = "application/vnd.sas.error+json"
  ;
  debug level=3;
run;







/*
* **************************************************************************************;
* * Get the myfolder uri;

FILENAME resp temp ENCODING='UTF-8' ;

PROC HTTP METHOD = "GET" oauth_bearer=sas_services OUT = resp IN = json_in
      URL = "&BASE_URI/folders/folders/@myFolder";
	debug level=3;
RUN;
LIBNAME resp json;

proc sql noprint;
  select parentFolderUri into :pfold_id trimmed from resp.root;
quit;

%put &pfold_id;

* **************************************************************************************;
* * Create a new empty temporary report in my folder (/Users/frasep, not in My folder subdir);

FILENAME json_in "/home/frasep/createReport.json" ENCODING='UTF-8' ;

data _null_;
   file json_in;
   input; 
   put _infile_;
   datalines4;
{
	"name":"Temp_report",
	"description":"Temporary report to delete"
}
;;;;

FILENAME resp temp ENCODING='UTF-8' ;
%let REST_QUERY_URI=&BASE_URI/reports/reports?parentFolderUri=&pfold_id;

PROC HTTP METHOD = "POST" oauth_bearer=sas_services OUT = resp IN = json_in
      URL = "&REST_QUERY_URI";
      HEADERS
		"Accept" = "application/vnd.sas.report+json"
		"Content-Type" = "application/vnd.sas.report+json";
	debug level=3;
RUN;

LIBNAME resp json;

proc sql noprint;
  select uri into :upd_url trimmed from resp.links where rel="updateContent";
quit;

%put &upd_url;

* **************************************************************************************;
* * Update the temporary report with the content of last state of original report;
* **************************************************************************************;
%let REST_QUERY_URI=&BASE_URI.&upd_url.;
%put &REST_QUERY_URI;

PROC HTTP METHOD = "PUT" oauth_bearer=sas_services OUT = resp IN = repJson
      URL = "&REST_QUERY_URI";
      HEADERS
		"Accept" = "application/vnd.sas.error+json"
		"Content-Type" = "application/vnd.sas.report.content+json";
	debug level=3;
RUN;

curl -X PUT https://example.com/reports/reports/{reportId}/content \
  -H 'Authorization: Bearer <access-token-goes-here>' \
  -H 'Content-Type: application/vnd.sas.report.content+json' \
  -H 'Accept: application/vnd.sas.error+json' \
  -H 'If-Match: string' \
  -H 'If-Unmodified-Since: string'

*/