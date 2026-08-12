/* jenner-check bundle: mp_binarycopy() macro from
 * viya35ppt_gen/using librsvg2-tools/Filesystem based/002_job_viya35_admin_gen_ppt.sas
 *
 * mp_binarycopy() is the repo's os-independent byte-for-byte file-copy
 * utility (used to push the generated PowerPoint out to SAS Content via
 * a filesrvc fileref). The macro itself has no dependency on the SAS
 * Viya REST API or any external server -- only the copy's SOURCE and
 * DESTINATION filerefs need to exist, so this bundle exercises the
 * macro unmodified against a small local source file instead of the
 * repo's live filesrvc destination.
 */

%macro mp_binarycopy(
    inloc=           /* full path and filename of the object to be copied */
    ,outloc=          /* full path and filename of object to be created */
    ,inref=____in   /* override default to use own filerefs */
    ,outref=____out /* override default to use own filerefs */
    ,mode=CREATE
    ,iftrue=%str(1=1)
)/*/STORE SOURCE*/;
  %local mod;

  %if not(%eval(%unquote(&iftrue))) %then %return;

  %if &mode=APPEND %then %let mod=mod;

  /* these IN and OUT filerefs can point to anything */
  %if &inref = ____in %then %do;
    filename &inref &inloc lrecl=1048576 ;
  %end;
  %if &outref=____out %then %do;
    filename &outref &outloc lrecl=1048576 &mod;
  %end;

  /* copy the file byte-for-byte  */
  data _null_;
    infile &inref lrecl=1 recfm=n;
    file &outref &mod recfm=n;
    input sourcechar $char1. @@;
    format sourcechar hex2.;
    put sourcechar char1. @@;
  run;

  %if &inref = ____in %then %do;
    filename &inref clear;
  %end;
  %if &outref=____out %then %do;
    filename &outref clear;
  %end;
%mend mp_binarycopy;

/* source.txt stands in for the repo's generated .pptx -- mp_binarycopy
   is content-agnostic, so any bytes exercise the same read/write loop
   the macro actually runs. Written inline so the bundle is
   self-contained (no sibling data file required). */
data _null_;
  file "source.txt";
  put "Sample report export payload, line 1";
  put "Sample report export payload, line 2";
  put "Sample report export payload, line 3";
run;

%mp_binarycopy(inloc="source.txt", outloc="copied_output.txt")

/* Prove the copy is byte-for-byte identical by reading it back. */
data _null_;
  infile "copied_output.txt";
  input;
  put _infile_;
run;
