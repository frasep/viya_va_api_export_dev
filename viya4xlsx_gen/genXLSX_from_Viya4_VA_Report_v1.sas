/**************************************************************************
  Combine exportable SAS Visual Analytics report objects into one XLSX
  workbook.

  Intended runtime:
    - SAS Viya 4 Compute Server
    - SAS Studio
    - SAS Job Execution Service

  Authentication:
    - OAUTH_BEARER=SAS_SERVICES

  Output:
    - One consolidated XLSX workbook
    - Index worksheet
    - One worksheet per successfully exported VA object

  Important:
    - REPORTID must be the report UUID, not /reports/reports/<uuid>.
    - Only objects supported by the VA XLSX export endpoint are included.
    - The exported sheets contain data, not a visual reproduction of charts.
**************************************************************************/




/*=======================================================================
  Helper macro: print an error and optionally stop the caller
=======================================================================*/

%macro va_error(message);
    %put ERROR: &message;
%mend va_error;


/*=======================================================================
  Helper macro: HTTP status validation
=======================================================================*/

%macro va_check_http(
      expected=200
    , context=
    , abort=N
);

    %global VA_HTTP_OK;
    %let VA_HTTP_OK=0;

    %if %symexist(SYS_PROCHTTP_STATUS_CODE) %then %do;

        %if &SYS_PROCHTTP_STATUS_CODE = &expected %then
            %let VA_HTTP_OK=1;
        %else %do;
            %put ERROR: &context failed.;
            %put ERROR: HTTP status = &SYS_PROCHTTP_STATUS_CODE;
            %put ERROR: HTTP reason = &SYS_PROCHTTP_STATUS_PHRASE;

            %if %upcase(&abort)=Y %then %do;
                %abort cancel;
            %end;
        %end;

    %end;
    %else %do;
        %put ERROR: PROC HTTP did not create SYS_PROCHTTP_STATUS_CODE.;

        %if %upcase(&abort)=Y %then %do;
            %abort cancel;
        %end;
    %end;

%mend va_check_http;


/*=======================================================================
  Helper macro: normalize report ID

  Accepted:
      UUID
      /reports/reports/UUID
=======================================================================*/

%macro va_normalize_report_id(report=);

    %global VA_REPORT_ID;

    data _null_;
        length supplied report_id $2048;

        supplied = strip(symget('report'));

        /*
          Extract the last non-empty path component.
          This supports either a UUID or a Reports API URI.
        */
        report_id = scan(supplied, -1, '/');

        call symputx('VA_REPORT_ID', report_id, 'G');
    run;

%mend va_normalize_report_id;


/*=======================================================================
  Discover report objects
=======================================================================*/

%macro va_get_report_objects(
      baseurl=
    , reportid=
    , outds=work.va_objects
);

    filename vaobjjs temp encoding="utf-8";
    filename vahdr   temp encoding="utf-8";

    proc http
        method="GET"
        url="&baseurl/visualAnalytics/reports/&reportid/reportObjects"
        oauth_bearer=sas_services
        out=vaobjjs
        headerout=vahdr;
        headers
            "Accept"="application/vnd.sas.collection+json";
    run;

    %va_check_http(
          expected=200
        , context=Retrieving Visual Analytics report objects
        , abort=Y
    );

    libname vaobjlib json
        fileref=vaobjjs
        automap=create
        map="%sysfunc(pathname(work))/va_report_objects.map";

    /*
      Most Viya 4 collection responses expose objects in an ITEMS table.

      VVALUEX is used so the program remains tolerant of minor differences
      in field naming between API versions.
    */
    %if %sysfunc(exist(vaobjlib.items)) %then %do;

        data &outds;
            length
                object_name  $512
                object_label $512
                object_type  $128
                object_id    $256
                page_name    $512
            ;

            set vaobjlib.items;

            object_name = coalescec(
                strip(vvaluex('name')),
                strip(vvaluex('label')),
                strip(vvaluex('id'))
            );

            object_label = coalescec(
                strip(vvaluex('label')),
                strip(vvaluex('name')),
                strip(vvaluex('id'))
            );

            object_type = coalescec(
                strip(vvaluex('type')),
                strip(vvaluex('objectType')),
                strip(vvaluex('visualType'))
            );

            object_id = coalescec(
                strip(vvaluex('id')),
                strip(vvaluex('objectId'))
            );

            page_name = coalescec(
                strip(vvaluex('pageName')),
                strip(vvaluex('sectionName'))
            );

            if not missing(object_name);

            keep
                object_name
                object_label
                object_type
                object_id
                page_name
            ;
        run;

    %end;
    %else %do;

        %va_error(
          No ITEMS table was found in the reportObjects JSON response.
          Inspect the VAOBJLIB library to adapt the parser to this release.
        );

        proc datasets library=vaobjlib;
        quit;

        %abort cancel;

    %end;

    libname vaobjlib clear;
    filename vaobjjs clear;
    filename vahdr clear;

%mend va_get_report_objects;


/*=======================================================================
  Export one VA report object as XLSX
=======================================================================*/

%macro va_export_object_xlsx(
      baseurl=
    , reportid=
    , object_name=
    , outfile=
);

    %global VA_EXPORT_OK;
    %let VA_EXPORT_OK=0;

    /*
      URL-encode the object name in a DATA step. This avoids macro quoting
      problems with spaces, ampersands, accented characters, and symbols.
    */
    data _null_;
        length raw encoded $32767;

        raw = symget('object_name');
        encoded = urlencode(strip(raw));

        call symputx('VA_ENCODED_OBJECT', encoded, 'G');
    run;

    filename vaxlsx "&outfile";
    filename vahdr  temp encoding="utf-8";

    proc http
        method="GET"
        url="&baseurl/visualAnalytics/reports/&reportid/xlsx?reportObject=&VA_ENCODED_OBJECT"
        oauth_bearer=sas_services
        out=vaxlsx
        headerout=vahdr;
        headers
            "Accept"=
              "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
    run;

    %if %symexist(SYS_PROCHTTP_STATUS_CODE) %then %do;
        %if &SYS_PROCHTTP_STATUS_CODE = 200 %then
            %let VA_EXPORT_OK=1;
        %else %do;
            %put INFO: Object export was skipped.;
            %put INFO: Object = %superq(object_name);
            %put INFO: HTTP status = &SYS_PROCHTTP_STATUS_CODE;
            %put INFO: HTTP reason = &SYS_PROCHTTP_STATUS_PHRASE;
        %end;
    %end;

    filename vaxlsx clear;
    filename vahdr clear;

%mend va_export_object_xlsx;


/*=======================================================================
  Import the first worksheet from an exported XLSX file
=======================================================================*/

%macro va_import_first_sheet(
      xlsx=
    , outds=
);

    %global VA_IMPORT_OK;
    %global VA_SOURCE_SHEET;

    %let VA_IMPORT_OK=0;
    %let VA_SOURCE_SHEET=;

    libname vaxlin xlsx "&xlsx" access=readonly;

    /*
      Detect the first worksheet exposed by the XLSX engine.
      NLITERAL creates a safe SAS name literal if the worksheet contains
      spaces or special characters.
    */
    proc sql noprint outobs=1;
        select
            memname,
            nliteral(trim(memname))
        into
            :VA_SOURCE_SHEET trimmed,
            :VA_SOURCE_MEMBER trimmed
        from dictionary.tables
        where libname = "VAXLIN"
          and memtype = "DATA"
        order by memname;
    quit;

    %if %superq(VA_SOURCE_MEMBER) ne %then %do;

        data &outds;
            set vaxlin.&VA_SOURCE_MEMBER;
        run;

        %if %sysfunc(exist(&outds)) %then
            %let VA_IMPORT_OK=1;

    %end;
    %else %do;
        %put WARNING: No worksheet was found in &xlsx..;
    %end;

    libname vaxlin clear;

%mend va_import_first_sheet;


/*=======================================================================
  Build unique, legal Excel worksheet names

  Excel restrictions addressed here:
    - Maximum 31 characters
    - Cannot contain: [ ] : * ? / \
    - Duplicate names avoided through numeric prefix
=======================================================================*/

%macro va_make_sheet_name(
      sequence=
    , label=
);

    %global VA_SHEET_NAME;

    data _null_;
        length
            original cleaned prefix final $512
        ;

        original = symget('label');

        /*
          Replace Excel-invalid worksheet-name characters.
        */
        cleaned = prxchange(
            's/[\[\]\:\*\?\/\\]+/_/o',
            -1,
            strip(original)
        );

        /*
          Remove control characters.
        */
        cleaned = compress(cleaned, , 'c');

        /*
          Avoid leading/trailing apostrophes and blank names.
        */
        cleaned = strip(cleaned);

        do while (
            lengthn(cleaned) > 0 and
            substr(cleaned,1,1) = "'"
        );
            cleaned = substr(cleaned,2);
        end;

        do while (
            lengthn(cleaned) > 0 and
            substr(cleaned,lengthn(cleaned),1) = "'"
        );
            cleaned = substr(cleaned,1,lengthn(cleaned)-1);
        end;

        if missing(cleaned) then
            cleaned = cats('VA_Object_', symget('sequence'));

        prefix = cats(
            put(input(symget('sequence'), best32.), z3.),
            '_'
        );

        /*
          Prefix guarantees uniqueness. Use only the remaining characters
          up to Excel's 31-character limit.
        */
        final = cats(
            prefix,
            substr(cleaned, 1, 31-length(prefix))
        );

        call symputx('VA_SHEET_NAME', final, 'G');
    run;

%mend va_make_sheet_name;


/*=======================================================================
  Write one imported dataset to the active ODS EXCEL workbook
=======================================================================*/

%macro va_write_sheet(
      data=
    , sheet=
    , object_label=
    , object_type=
);

    ods excel options(
        sheet_name="&sheet"
        embedded_titles="yes"
        frozen_headers="yes"
        autofilter="all"
        flow="tables"
    );

    title1 "&object_label";

    %if %superq(object_type) ne %then %do;
        title2 "Visual Analytics object type: &object_type";
    %end;

    proc report data=&data nowd;
    run;

    title;
    footnote;

%mend va_write_sheet;


/*=======================================================================
  Main macro
=======================================================================*/

%macro va_report_to_xlsx(
      report=
    , outfile=
    , baseurl=
    , include_index=Y
    , debug=N
);

    %local
        i
        object_count
        success_count
        failure_count
        work_path
        current_file
        current_ds
        current_name
        current_label
        current_type
        current_page
        current_id
    ;

    %let success_count=0;
    %let failure_count=0;

    /*
      Derive the Viya gateway URL automatically when running inside Viya.
    */
    %if %superq(baseurl)= %then
        %let baseurl=%sysfunc(getoption(servicesbaseurl));

    /*
      Remove a trailing slash to prevent double slashes in API URLs.
    */
    %if %qsubstr(%superq(baseurl),%length(%superq(baseurl)),1)=%str(/)
        %then %let baseurl=
            %qsubstr(%superq(baseurl),1,%eval(%length(%superq(baseurl))-1));

    %if %superq(report)= %then %do;
        %va_error(REPORT= is required.);
        %return;
    %end;

    %if %superq(outfile)= %then %do;
        %va_error(OUTFILE= is required.);
        %return;
    %end;

    %if %superq(baseurl)= %then %do;
        %va_error(
          BASEURL could not be derived from SERVICESBASEURL.
          Supply BASEURL=https://your-viya-host.
        );
        %return;
    %end;

    %va_normalize_report_id(report=&report);

    %let work_path=%sysfunc(pathname(work));

    %put NOTE: Viya base URL = &baseurl;
    %put NOTE: VA report ID = &VA_REPORT_ID;
    %put NOTE: Consolidated workbook = &outfile;

    /*
      1. Get the report's objects.
    */
    %va_get_report_objects(
          baseurl=&baseurl
        , reportid=&VA_REPORT_ID
        , outds=work.va_objects
    );

    proc sql noprint;
        select count(*)
        into :object_count trimmed
        from work.va_objects;
    quit;

    %if &object_count = 0 %then %do;
        %va_error(No report objects were returned.);
        %return;
    %end;

    /*
      Put object metadata into macro variables.
    */
    data _null_;
        set work.va_objects;

        call symputx(
            cats('VA_NAME_',_n_),
            object_name,
            'L'
        );

        call symputx(
            cats('VA_LABEL_',_n_),
            object_label,
            'L'
        );

        call symputx(
            cats('VA_TYPE_',_n_),
            object_type,
            'L'
        );

        call symputx(
            cats('VA_PAGE_',_n_),
            page_name,
            'L'
        );

        call symputx(
            cats('VA_ID_',_n_),
            object_id,
            'L'
        );
    run;

    /*
      Mapping table used by the index worksheet.
    */
    data work.va_export_index;
        length
            sequence        8
            page_name       $512
            object_label    $512
            object_name     $512
            object_type     $128
            object_id       $256
            worksheet_name  $31
            export_status   $32
            http_status     8
            http_reason     $256
            source_sheet    $256
            dataset_name    $41
        ;

        stop;
    run;

    /*
      2. Export and import each object.
    */
    %do i=1 %to &object_count;

        %let current_name=&&VA_NAME_&i;
        %let current_label=&&VA_LABEL_&i;
        %let current_type=&&VA_TYPE_&i;
        %let current_page=&&VA_PAGE_&i;
        %let current_id=&&VA_ID_&i;

        %let current_file=&work_path/va_object_%sysfunc(putn(&i,z4.)).xlsx;
        %let current_ds=work.vaobj_%sysfunc(putn(&i,z4.));

        %put NOTE: --------------------------------------------------;
        %put NOTE: Exporting object &i of &object_count;
        %put NOTE: Object name = %superq(current_name);
        %put NOTE: Object label = %superq(current_label);

        %va_make_sheet_name(
              sequence=&i
            , label=&current_label
        );

        %va_export_object_xlsx(
              baseurl=&baseurl
            , reportid=&VA_REPORT_ID
            , object_name=&current_name
            , outfile=&current_file
        );

        %if &VA_EXPORT_OK = 1 %then %do;

            %va_import_first_sheet(
                  xlsx=&current_file
                , outds=&current_ds
            );

            %if &VA_IMPORT_OK = 1 %then %do;

                %let success_count=%eval(&success_count+1);

                data work.va_index_row;
                    length
                        sequence        8
                        page_name       $512
                        object_label    $512
                        object_name     $512
                        object_type     $128
                        object_id       $256
                        worksheet_name  $31
                        export_status   $32
                        http_status     8
                        http_reason     $256
                        source_sheet    $256
                        dataset_name    $41
                    ;

                    sequence       = &i;
                    page_name      = symget('current_page');
                    object_label   = symget('current_label');
                    object_name    = symget('current_name');
                    object_type    = symget('current_type');
                    object_id      = symget('current_id');
                    worksheet_name = symget('VA_SHEET_NAME');
                    export_status  = 'Exported';
                    http_status    = 200;
                    http_reason    = 'OK';
                    source_sheet   = symget('VA_SOURCE_SHEET');
                    dataset_name   = symget('current_ds');
                run;

            %end;
            %else %do;

                %let failure_count=%eval(&failure_count+1);

                data work.va_index_row;
                    length
                        sequence        8
                        page_name       $512
                        object_label    $512
                        object_name     $512
                        object_type     $128
                        object_id       $256
                        worksheet_name  $31
                        export_status   $32
                        http_status     8
                        http_reason     $256
                        source_sheet    $256
                        dataset_name    $41
                    ;

                    sequence       = &i;
                    page_name      = symget('current_page');
                    object_label   = symget('current_label');
                    object_name    = symget('current_name');
                    object_type    = symget('current_type');
                    object_id      = symget('current_id');
                    worksheet_name = '';
                    export_status  = 'Import failed';
                    http_status    = 200;
                    http_reason    = 'XLSX returned, but no sheet imported';
                    source_sheet   = '';
                    dataset_name   = '';
                run;

            %end;

        %end;
        %else %do;

            %let failure_count=%eval(&failure_count+1);

            data work.va_index_row;
                length
                    sequence        8
                    page_name       $512
                    object_label    $512
                    object_name     $512
                    object_type     $128
                    object_id       $256
                    worksheet_name  $31
                    export_status   $32
                    http_status     8
                    http_reason     $256
                    source_sheet    $256
                    dataset_name    $41
                ;

                sequence       = &i;
                page_name      = symget('current_page');
                object_label   = symget('current_label');
                object_name    = symget('current_name');
                object_type    = symget('current_type');
                object_id      = symget('current_id');
                worksheet_name = '';
                export_status  = 'Not exportable';
                http_status    = input(
                    symget('SYS_PROCHTTP_STATUS_CODE'),
                    best32.
                );
                http_reason    = symget('SYS_PROCHTTP_STATUS_PHRASE');
                source_sheet   = '';
                dataset_name   = '';
            run;

        %end;

        proc append
            base=work.va_export_index
            data=work.va_index_row
            force;
        run;

        proc datasets library=work nolist;
            delete va_index_row;
        quit;

    %end;

    /*
      Do not generate an empty workbook if no object was exportable.
    */
    %if &success_count = 0 %then %do;

        %va_error(
          None of the report objects could be exported and imported.
          Review WORK.VA_EXPORT_INDEX and the SAS log.
        );

        proc print data=work.va_export_index noobs;
        run;

        %return;

    %end;

    /*
      3. Produce the final consolidated workbook.
    */
    ods _all_ close;

    ods excel
        file="&outfile"
        options(
            embedded_titles="yes"
            frozen_headers="yes"
            autofilter="all"
            flow="tables"
        );

    %if %upcase(&include_index)=Y %then %do;

        ods excel options(
            sheet_name="Index"
            embedded_titles="yes"
            frozen_headers="yes"
            autofilter="all"
        );

        title1 "Visual Analytics report export";
        title2 "Report ID: &VA_REPORT_ID";
        title3
          "Successfully exported: &success_count; skipped or failed: &failure_count";

        proc report data=work.va_export_index nowd;
            columns
                sequence
                page_name
                object_label
                object_type
                worksheet_name
                export_status
                http_status
                http_reason
            ;

            define sequence /
                display
                "Order";

            define page_name /
                display
                "Report page";

            define object_label /
                display
                "VA object";

            define object_type /
                display
                "Object type";

            define worksheet_name /
                display
                "Worksheet";

            define export_status /
                display
                "Status";

            define http_status /
                display
                "HTTP";

            define http_reason /
                display
                "Details";
        run;

        title;

    %end;

    /*
      Write each successfully imported dataset.
    */
    proc sql noprint;
        select count(*)
        into :VA_WRITE_COUNT trimmed
        from work.va_export_index
        where export_status = 'Exported';
    quit;

    data _null_;
        set work.va_export_index(
            where=(export_status='Exported')
        );

        call symputx(
            cats('VA_WRITE_DS_',_n_),
            dataset_name,
            'L'
        );

        call symputx(
            cats('VA_WRITE_SHEET_',_n_),
            worksheet_name,
            'L'
        );

        call symputx(
            cats('VA_WRITE_LABEL_',_n_),
            object_label,
            'L'
        );

        call symputx(
            cats('VA_WRITE_TYPE_',_n_),
            object_type,
            'L'
        );
    run;

    %do i=1 %to &VA_WRITE_COUNT;

        %va_write_sheet(
              data=&&VA_WRITE_DS_&i
            , sheet=&&VA_WRITE_SHEET_&i
            , object_label=&&VA_WRITE_LABEL_&i
            , object_type=&&VA_WRITE_TYPE_&i
        );

    %end;

    ods excel close;

    /*
      Restore the common HTML destination for interactive SAS Studio use.
    */
    ods html5;

    %put NOTE: ======================================================;
    %put NOTE: VA consolidated workbook created successfully.;
    %put NOTE: Output file: &outfile;
    %put NOTE: Exported objects: &success_count;
    %put NOTE: Skipped or failed objects: &failure_count;
    %put NOTE: Details: WORK.VA_EXPORT_INDEX;
    %put NOTE: ======================================================;

    %if %upcase(&debug) ne Y %then %do;

        /*
          Imported WORK datasets are retained until session termination.
          Keeping them is helpful if the caller wants to inspect the data.
          The source XLSX files are automatically removed with WORK.
        */

    %end;

%mend va_report_to_xlsx;



/**********************************************************************************************************/
/**********************************************************************************************************/


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

%va_report_to_xlsx(
      report=&reportId
    , outfile=%sysget(HOME)/VA_Report_Export.xlsx
    , include_index=Y
);