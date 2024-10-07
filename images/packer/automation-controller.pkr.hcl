variable "project_id" {
    type    = string
    default = "red-hat-mbu"
}

variable "zone" {
    type    = string
    default = "us-east1-b"
}

variable "image_name" {
    type    = string
    default = "aap-25-ceh-20241004-2"
}

variable "ansible_vars_file" {
    type    = string
    default = null
}

local "extra_args" {
    expression = var.ansible_vars_file != null ? ["-e", "@images/aap/extra-vars.yml", "-e", "ansible_python_interpreter=/usr/bin/python3", "-e", var.ansible_vars_file, "-vvvv"] : ["-e", "@images/aap/extra-vars.yml", "-e", "ansible_python_interpreter=/usr/bin/python3", "-vv"]
}

source "googlecompute" "automation-controller" {
    project_id          = var.project_id
    source_image_family = "rhel-9"
    ssh_username        = "rhel"
    wait_to_add_ssh_keys = "60s"
    zone                = var.zone
    machine_type        = "n1-standard-8"
    image_name          = var.image_name
}


build {
    sources = ["sources.googlecompute.automation-controller"]

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
          "cd /tmp/ansible-automation-platform-containerized-setup-2.5-1",
          "ANSIBLE_COLLECTIONS_PATH=/tmp/ansible-automation-platform-containerized-setup-2.5-1/collections ansible-playbook -v -i inventory.custom ansible.containerized_installer.install"
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