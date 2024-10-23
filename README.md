# aap-images

Project to build AAP images for Instruqt


Install packer and gcloud cli. Install packer plugins for gcloud and ansible
```
packer plugins install github.com/hashicorp/ansible
packer plugins install github.com/hashicorp/googlecompute
```

Auth to google
```
gcloud auth application-default login
```

## Build images

There's just one packer file that can build all flavors of Ansible Automation Platform. It is driven by the variables passed to the build command:
```
packer build -force -var aap_include_controller=true -var aap_include_automation_hub=false -var aap_include_eda_controller=false images/packer/automation-controller.pkr.hcl
```