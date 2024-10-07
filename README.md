# aap-images

Project to build AAP images for Instruqt

Images:
- ansible-controller-25: all-in-one install for a single VM


Install packer and gcloud cli. Install packer plugins for gcloud and ansible
```
packer plugins install github.com/hashicorp/ansible
packer plugins install github.com/hashicorp/googlecompute
```

Auth to google
```
gcloud auth application-default login
```