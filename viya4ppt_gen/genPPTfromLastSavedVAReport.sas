/*****************************************************************************************************************/
/* Get the current user last saved report in the same day                                                        */
/* in the &rep_id and &REPORT_NAME and &modtime output macro variables                                           */
/*****************************************************************************************************************/
/* VYE : Add a main flag to stop the process if there's no report today for the user instead of using endsas */
%global stop_flag;
%let stop_flag=0;

%let v_home=%sysget(HOME);
%put &=v_home;
%let USER_ID=&sysuserid; /* Get calling user id */
/*****************************************************************************************************************/
/* Get the base_uri to make all API calls */
%let base_uri=%sysfunc(getoption(SERVICESBASEURL));
* **************************************************************************************;
* *Get the id of the last report saved by the user specified in parameter **************;
* **************************************************************************************;
FILENAME rptFile TEMP ENCODING='UTF-8';

PROC HTTP
    METHOD="GET" 
    oauth_bearer=sas_services 
    OUT=rptFile 
    URL="&base_uri/reports/reports"
    QUERY=(
        "filter"="or(eq(modifiedBy,'&USER_ID'),eq(createdBy,'&USER_ID'))" 
        "sortBy"="modifiedTimeStamp:descending"
        "limit"="1"
    );
    HEADERS
        "Accept"="application/vnd.sas.collection+json";
    debug level=0;
RUN;

LIBNAME rptFile json;

data _null_;
    if 0 then set rptFile.items nobs=n;
    if n=0 then do;
        put "NOTE: No saved report for user &USER_ID";
        /* VYE : Replaced endsas with stop_flag */
        /* call execute('endsas;'); */
        call execute('%let stop_flag=1;');
    end;
    stop;
run;

%if &stop_flag=0 %then %do;
    /* Get only report saved during the current date */
    proc sql;
        select count(*) into :n_report trimmed from rptFile.items where
            input(substr(ModifiedTimeStamp,1,10), yymmdd10.) >= today() ;
    quit;
    %put Dbg &=&n_report.;

    /* Stop if no recent report save occurred */
    data TB_DBG /*_null_*/;
        if &n_report=0 then do;
            put
                "**********************************************************************************";
            put "NOTE: No saved report today for user &USER_ID";
            put
                "**********************************************************************************";
            /* VYE : Replaced endsas with stop_flag */
            /* call execute('endsas;'); */
            call execute('%let stop_flag=1;');
        end;
        stop;
    run;
%end;

%macro process_report;
proc sql noprint;
    select id into :rep_id trimmed from rptFile.items;
quit;
proc sql noprint;
    select name into :REPORT_NAME trimmed from rptFile.items;
quit;
proc sql noprint;
    select ModifiedTimeStamp into :modtime trimmed from rptFile.items;
quit;
%put Dbg_RepId_01 &=rep_id --- &=REPORT_NAME --- &=modtime;

%let reportId=%trim(&rep_id);
%let pptpath=&v_home;
%let width=2880px;
%let height=1620px;

%let cleanstr = %sysfunc(transtrn(&REPORT_NAME, /, _));
%let cleanstr = %sysfunc(transtrn(&cleanstr, :, _));
%let cleanstr = %sysfunc(transtrn(&cleanstr, %str( ), _));

%let fullpptfilename="&pptpath./&cleanstr..pptx";

%put reportId       : # &reportId #;
%put reportName     : # &REPORT_NAME #;
/* VYE : Removed the next line because &_pptfilename is not defined. */
/* %put _pptfilename   : # &_pptfilename #; */
%put pptpath        : # &pptpath #;
%put fullpptfilename: # &fullpptfilename #;

/******************************************************************/
/* Create the macro to generate a png image from a report section */
/******************************************************************/

%macro export_va_report_png(report_id, out_png, rep_obj, width, height);
    /* VYE : Removed the next line because of warnings with %nrstr(&)size that is not a macro. Using instead query= from PROC HTTP */
   /* %let theurl = &base_uri./visualAnalytics/reports/&report_Id/png?reportObject=&rep_obj.%nrstr(&)size=&width,&height; */
   filename imgfile "&pptpath./&out_png";
   proc http
      /* VYE : Replaced the next line with the root url link */
      /* url = "&theurl" */
      url = "&base_uri./visualAnalytics/reports/&report_Id/png"
      method = "GET"
      oauth_bearer = sas_services
      out = imgfile
      /* VYE : Added query= parameters */
      query=("reportObject"="&rep_obj" "size"="&width,&height");
      headers
         "Accept" = "image/png, application/json, application/vnd.sas.error+json, application/json";
   run;
   filename imgfile clear;
%mend export_va_report_png;

/******************************************************************/
/* Get the list of sections of the report */
/******************************************************************/

filename varesp temp encoding='UTF-8'; 

proc http
    url = "&base_uri./reports/reports/&reportId/content/elements"
    method = "GET"
    oauth_bearer = sas_services
    out=varesp;
run;

libname repelt json fileref=varesp;

proc sql;
   create table sections as select ordinal_items, name
   from repelt.items
   where type='Section' and hidden=0
   order by ordinal_items asc;
run;

/******************************************************************/
/* Generate all the image for all the section of the report       */
/******************************************************************/

data _null_;
    set sections;
    length h $10 w $10 rid $100;
    /* Assign macro values to local variables for clarity */
    h = symget('height');
    w = symget('width');
    rid = symget('reportId');
    /* Generate export macro call for each section */
    call execute(cats('%export_va_report_png(', rid, ',', name, '.png',',',name,',', w, ',', h, ')'));
run;

%macro print_images(filename, titl,folder);
	/* title "&titl" ;*//* */
	data _NULL_;
	 	dcl odsout obj();
        /* VYE : Changed height and width to 100% instead of 1080*1920 */
		obj.image(file:"&folder/&filename..png", height:"100%", width:"100%");
	run;
%mend;

%macro generate_ppt_file(report_id);
	options papersize=(19.2cm 10.8cm);
	filename ppt temp;
	data _NULL_;
	  set sections;
	  file ppt;
	  length line $ 2048;
	  line = cats('%let v_label="',name,'";');
	  put line;
	  putlog line;
	  line = cats('%print_images(', cats("filename=", name), ',titl=%superq(v_label),', cats("folder=","&pptpath."), ");");
    put line;
	  putlog line;
	run;

	/*DBG ods html5 exclude all;*/
	ods powerpoint file=%sysfunc(quote(&fullpptfilename));
 	%inc ppt / source2;
	ods powerpoint close;
%mend generate_ppt_file;

%generate_ppt_file(reportId);

/* VYE : Add a %process_report macro, launch only if stop_flag=0 (a report from today is found for the user) */
%mend process_report;
%if &stop_flag=0 %then %do;
%process_report;
%end;