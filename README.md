# viya_va_api_export_dev

The purpose of this project is to allow programmatic approach to SAS Viya (one for 3.5 and one for Viya 4) Visual Analytics report export through API and ODS Powerpoint use.

## For SAS Viya 3.5 (viya35ppt_gen subdirectory)

Find below a diagram explaining the cinematic implemented through the scripts provided in this project subfolder.
It has been tested on SAS Viya 3.5 environment installed on RHEL 7.9.
There are two versions of tools tested :
- inkscape tool has been installed with the following command : sudo yum install inkscape. The release of Inkscape used for this test was 0.92.
- librsvg2-tools library has been used. It must be installed as it is used to convert svg to png. The follwing version has been tested : librsvg2-tools.x86_64 0:2.40.20-1.el7


![viya35_cinematic_diagram.png](./viya35ppt_gen/viya35_cinematic_diagram.png)


## For SAS Viya 4 (tested of 2023.11 and later) (viya4ppt_gen subdirectory)

With Viya 4 there is no need to go though an external tool to generate png as the Voya 4 API expose directly the png image endpoint for VA repoet or report object.
