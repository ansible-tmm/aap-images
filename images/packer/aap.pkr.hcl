packer {
  required_plugins {
    ansible = {
      version = ">= v1.1.2"
      source = "github.com/hashicorp/ansible"
    }
    amazon = {
      version = ">= v1.2.8"
      source = "github.com/hashicorp/amazon"
    }
  }
}


variable "aws_region" {
    type    = string
    default = "us-east-1"
}

variable "instance_type" {
    type    = string
    default = "m5.4xlarge"
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

source "amazon-ebs" "automation-controller" {
    region          = var.aws_region
    source_ami_filter {
        filters = {
            name                = "RHEL-9.*_HVM-*-x86_64-*-Hourly2-GP2"
            root-device-type    = "ebs"
            virtualization-type = "hvm"
        }
        most_recent = true
        owners      = ["309956199498"] # Red Hat
    }
    instance_type = var.instance_type
    ssh_username  = "ec2-user"
    ami_name      = "aap-temp-${local.image_label}-${formatdate("YYYYMMDD", timestamp())}"
    
    launch_block_device_mappings {
        device_name = "/dev/sda1"
        volume_size = 30
        volume_type = "gp3"
        delete_on_termination = true
    }
}

build {
    sources = ["sources.amazon-ebs.automation-controller"]

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

    // Create rhel user for compatibility with Google Cloud images
    provisioner "shell" {
        inline = [
            "sudo useradd -m -s /bin/bash rhel",
            "sudo usermod -aG wheel rhel",
            "echo 'rhel ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/rhel",
            "sudo mkdir -p /home/rhel/.ssh",
            "sudo cp /home/ec2-user/.ssh/authorized_keys /home/rhel/.ssh/",
            "sudo chown -R rhel:rhel /home/rhel/.ssh",
            "sudo chmod 700 /home/rhel/.ssh",
            "sudo chmod 600 /home/rhel/.ssh/authorized_keys"
        ]
    }

    // Pre install tasks
    provisioner "ansible" {
        command = "ansible-playbook"
        playbook_file = "${path.root}/../aap/playbooks/pre-install.yml"
        user = "ec2-user"
        inventory_file_template = "controller ansible_host={{ .Host }} ansible_user={{ .User }} ansible_port={{ .Port }}\n"
        use_proxy = false
        extra_arguments = local.extra_args
    }

    // Update AMI name with extracted version
    provisioner "shell-local" {
        inline = [
            "# Extract version from the build",
            "if [ -f /tmp/version.txt ]; then",
            "  AAP_VERSION=$(grep installer_version /tmp/version.txt | cut -d= -f2)",
            "  echo \"Extracted AAP Version: $AAP_VERSION\"",
            "  # Update the AMI name in the manifest for final naming",
            "  echo \"Final AMI will be named: aap-$AAP_VERSION-${local.image_label}-${formatdate("YYYYMMDD", timestamp())}\"",
            "else",
            "  echo \"Warning: /tmp/version.txt not found, using default naming\"",
            "fi"
        ]
    }

    // Platform install
    provisioner "shell" {
        inline = [
            "if [ -d /tmp/ansible-automation-platform-containerized-setup ]; then",
            "  cd /tmp/ansible-automation-platform-containerized-setup",
            "  ANSIBLE_COLLECTIONS_PATH=/tmp/ansible-automation-platform-containerized-setup/collections ansible-playbook -v -i inventory.custom ansible.containerized_installer.install",
            "else",
            "  echo 'Directory /tmp/ansible-automation-platform-containerized-setup does not exist.'",
            "  ls /tmp",
            "  exit 1",
            "fi"
        ]
    }

    // Post install tasks
    provisioner "ansible" {
        command = "ansible-playbook"
        playbook_file = "${path.root}/../aap/playbooks/post-install.yml"
        user = "ec2-user"
        inventory_file_template = "controller ansible_host={{ .Host }} ansible_user={{ .User }} ansible_port={{ .Port }}\n"
        use_proxy = false
        extra_arguments = local.extra_args
    }

    post-processor "manifest" {
        output = "manifest.json"
        strip_path = true
    }
}
