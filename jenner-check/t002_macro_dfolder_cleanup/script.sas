/* jenner-check bundle: dfile() / dfolder() / remove() macros from
 * viya35ppt_gen/using librsvg2-tools/Filesystem based/002_job_viya35_admin_gen_ppt.sas
 *
 * These macros are the repo's job-directory cleanup routine: dfile()
 * deletes a single named file, dfolder() lists and deletes every file
 * inside a directory, and remove() drives dfolder()+dfile() across a
 * data-step-built list of job directories. None of the three touch the
 * SAS Viya REST API -- they only need real directories and files on
 * disk, so this bundle creates a small job-directory tree and lets the
 * repo's own cleanup macros run against it unmodified.
 */

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

/* Build a small job-directory tree standing in for
 * &SAVE_ROOTDIR/&USER_ID/&rep_id used by the repo's admin job. */
data _null_;
  rc0 = dcreate("jobdirs_demo", ".");
  rc1 = dcreate("job_a", "./jobdirs_demo");
  rc2 = dcreate("job_b", "./jobdirs_demo");
run;

data _null_;
  file "./jobdirs_demo/job_a/1_SectionA.svg";
  put "<svg>section a</svg>";
run;
data _null_;
  file "./jobdirs_demo/job_a/2_SectionB.svg";
  put "<svg>section b</svg>";
run;
data _null_;
  file "./jobdirs_demo/job_b/1_SectionA.svg";
  put "<svg>section a (job b)</svg>";
run;

/* list existing job directories, mirroring the repo's own scan */
data jobdirs;
	rc=filename("mydir","./jobdirs_demo");
	did=dopen("mydir");
	n_obs=dnum(did);
	call symput('ndirs',dnum(did));
	if n_obs>=1 then
	do;
		do i = 1 to n_obs;
	 		dname="./jobdirs_demo/" || dread(did,i);
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

proc print data=jobdirs;
  title "job directories found before cleanup";
run;

%remove();

/* Prove the cleanup actually ran: the files inside each job directory
 * should be gone (dfolder/dfile delete file contents; the directory
 * entries themselves are left in place, matching the repo's own
 * %remove() semantics). */
data _null_;
  rc_a1 = fileexist("./jobdirs_demo/job_a/1_SectionA.svg");
  rc_a2 = fileexist("./jobdirs_demo/job_a/2_SectionB.svg");
  rc_b1 = fileexist("./jobdirs_demo/job_b/1_SectionA.svg");
  put "job_a/1_SectionA.svg exists after cleanup (0=no): " rc_a1;
  put "job_a/2_SectionB.svg exists after cleanup (0=no): " rc_a2;
  put "job_b/1_SectionA.svg exists after cleanup (0=no): " rc_b1;
run;
