variable "project_id" {
    type    = string
    default = "red-hat-mbu"
}

variable "zone" {
    type    = string
    default = "us-east1-b"
}

variable "aap_include_controller" {
    type    = bool
    default = true
}

variable "aap_include_automation_hub" {
    type    = bool
    default = false
}

variable "aap_include_eda_controller" {
    type    = bool
    default = false
}

variable "ansible_vars_file" {
    type    = string
    default = null
}

locals {
    // Define components with enabled flags and labels
    aap_components = {
        controller = {
            enabled = var.aap_include_controller
            label   = "c"
        }
        eda_controller = {
            enabled = var.aap_include_eda_controller
            label   = "e"
        }
        automation_hub = {
            enabled = var.aap_include_automation_hub
            label   = "h"
        }
    }

    // Construct the image label based on enabled components (sorted alphabetically)
    enabled_labels = sort([for key, component in local.aap_components : component.label if component.enabled])
    image_label    = join("", local.enabled_labels)
    image_name     = "aap-25-${local.image_label}-${formatdate("YYYYMMDD", timestamp())}"

    // Create ansible vars argument list depending on the presence of ansible_vars_file
    extra_args_file = var.ansible_vars_file != null ? ["-e", var.ansible_vars_file, "-vvvv"] : ["-vv"]
    extra_args_common = [
        "-e", "@images/aap/extra-vars.yml",
        "-e", "ansible_python_interpreter=/usr/bin/python3",
        "-e", "aap_include_controller=${var.aap_include_controller}",
        "-e", "aap_include_automation_hub=${var.aap_include_automation_hub}",
        "-e", "aap_include_eda_controller=${var.aap_include_eda_controller}"
    ]

    // Combine arguments into extra_args
    extra_args = concat(local.extra_args_common, local.extra_args_file)
}

source "googlecompute" "automation-controller" {
    project_id          = var.project_id
    source_image_family = "rhel-9"
    ssh_username        = "rhel"
    wait_to_add_ssh_keys = "60s"
    zone                = var.zone
    machine_type        = "n1-standard-8"
    image_name          = local.image_name
}

build {
    sources = ["sources.googlecompute.automation-controller"]

    // Pre-build debug
    provisioner "shell" {
        inline = ["echo 'Building image with name: ${local.image_name}'"]
    }  

    // Pre-build debug to print the values of key variables
    provisioner "shell" {
        inline = [
            "echo '////////////////////////////'",
            "echo '// Debugging Packer Variables:'",
            "echo '// aap_include_controller=${var.aap_include_controller}'",
            "echo '// aap_include_automation_hub=${var.aap_include_automation_hub}'",
            "echo '// aap_include_eda_controller=${var.aap_include_eda_controller}'",
            "echo '// Generated image name: ${local.image_name}'",
            "echo '////////////////////////////'"
        ]
    }

    // Pre install tasks
    provisioner "ansible" {
        command = "ansible-playbook"
        playbook_file = "${path.root}/../aap/playbooks/pre-install.yml"
        user = "rhel"
        inventory_file_template = "controller ansible_host={{ .Host }} ansible_user={{ .User }} ansible_port={{ .Port }}\n"
        use_proxy = false
        extra_arguments = local.extra_args
    }

    // Platform install
    provisioner "shell" {
        inline = [
            "cd /tmp/ansible-automation-platform-containerized-setup-2.5-2",
            "ANSIBLE_COLLECTIONS_PATH=/tmp/ansible-automation-platform-containerized-setup-2.5-2/collections ansible-playbook -v -i inventory.custom ansible.containerized_installer.install"
        ]
    }

    // Post install tasks
    provisioner "ansible" {
        command = "ansible-playbook"
        playbook_file = "${path.root}/../aap/playbooks/post-install.yml"
        user = "rhel"
        inventory_file_template = "controller ansible_host={{ .Host }} ansible_user={{ .User }} ansible_port={{ .Port }}\n"
        use_proxy = false
        extra_arguments = local.extra_args
    }
}
