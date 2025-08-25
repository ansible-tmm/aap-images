packer {
  required_plugins {
    ansible = {
      version = ">= v1.1.2"
      source = "github.com/hashicorp/ansible"
    }
    qemu = {
      version = ">= v1.1.0"
      source = "github.com/hashicorp/qemu"
    }
    amazon = {
      version = ">= v1.2.8"
      source = "github.com/hashicorp/amazon"
    }
  }
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

variable "s3_bucket" {
    type    = string
    default = "aap-qcow2-images"
}

variable "aws_region" {
    type    = string
    default = "us-east-1"
}

variable "aap_version" {
    type    = string
    default = null
    description = "AAP version to use for naming. If not provided, version will be extracted from the installer."
}

locals {
    // Define components with enabled flags and labels (lowercase)
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
    
    // Output filename with version placeholder
    output_filename = "aap-${local.image_label}-${formatdate("YYYYMMDD", timestamp())}"
}

source "qemu" "rhel9" {
    // Use RHEL 9 qcow2 image downloaded from S3
    iso_url = "file:///tmp/rhel-9-cloud.qcow2"
    iso_checksum = "md5:155c1ded0cf6f0eebbfcfa5839586ea2"
    
    // Use qcow2 format for direct output
    format = "qcow2"
    disk_image = true
    use_default_display = true
    
    // VM configuration
    memory = 8192
    cpus = 4
    disk_size = "30G"
    
    // Network and SSH configuration
    ssh_username = "ec2-user"
    ssh_timeout = "20m"
    ssh_wait_timeout = "20m"
    
    // Output configuration
    vm_name = "${local.output_filename}.qcow2"
    output_directory = "output-qemu"
    
    // Boot configuration for cloud image
    boot_wait = "10s"
    boot_command = []
    
    // QEMU specific settings
    qemu_binary = "qemu-system-x86_64"
    machine_type = "pc"
    net_device = "virtio-net"
    disk_interface = "virtio"
    
}

build {
    sources = ["source.qemu.rhel9"]

    // Pre-build debug
    provisioner "shell" {
        inline = ["echo 'Building AAP qcow2 image with components: ${local.image_label}'"]
    }


    // Create rhel user and setup SSH
    provisioner "shell" {
        inline = [
            "sudo useradd -m -s /bin/bash rhel || true",
            "sudo usermod -aG wheel rhel",
            "echo 'rhel ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/rhel",
            "sudo mkdir -p /home/rhel/.ssh",
            "sudo cp /home/ec2-user/.ssh/authorized_keys /home/rhel/.ssh/ || true",
            "sudo chown -R rhel:rhel /home/rhel/.ssh",
            "sudo chmod 700 /home/rhel/.ssh",
            "sudo chmod 600 /home/rhel/.ssh/authorized_keys || true"
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

    // Extract version information from the VM and save to build environment
    provisioner "shell" {
        inline = [
            "# Extract version from version.txt on the VM",
            "if [ -f /tmp/ansible-automation-platform-containerized-setup/version.txt ]; then",
            "  AAP_VERSION=$(grep installer_version /tmp/ansible-automation-platform-containerized-setup/version.txt | cut -d= -f2 | tr -d \"[]'\" | sed 's/bundle-//' | sed 's/-x86_64//')",
            "  echo \"Extracted AAP Version: $AAP_VERSION\"",
            "  echo \"$AAP_VERSION\" > /tmp/aap_version.txt",
            "  echo \"Version saved to /tmp/aap_version.txt\"",
            "else",
            "  echo \"Error: version.txt not found, cannot determine AAP version\"",
            "  exit 1",
            "fi"
        ]
    }
    
    // Download the version file from the VM to the Packer host
    provisioner "file" {
        source = "/tmp/aap_version.txt"
        destination = "/tmp/aap_version_${build.ID}.txt"
        direction = "download"
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

    // Image cleanup
    provisioner "shell" {
        inline = [
            "# Clean package cache",
            "sudo dnf clean all",
            "# Remove temporary files", 
            "sudo rm -rf /tmp/*",
            "sudo rm -rf /var/tmp/*",
            "# Clear bash history",
            "history -c",
            "sudo rm -f /root/.bash_history",
            "sudo rm -f /home/ec2-user/.bash_history",
            "sudo rm -f /home/rhel/.bash_history || true",
            "# Zero out free space to help compression",
            "sudo dd if=/dev/zero of=/EMPTY bs=1M || true",
            "sudo rm -f /EMPTY"
        ]
    }

    // Generate manifest for tracking
    post-processor "manifest" {
        output = "manifest-qemu.json"
        strip_path = true
    }
    
    // Upload to S3 using shell script
    provisioner "shell-local" {
        inline = [
            "echo 'Uploading qcow2 image to S3...'",
            "${var.aap_version != null ? "AAP_VERSION=\"${var.aap_version}\"" : "AAP_VERSION=$(cat /tmp/aap_version_*.txt)"}",
            "FILENAME=\"aap-$AAP_VERSION-${local.image_label}-${formatdate("YYYYMMDD", timestamp())}.qcow2\"",
            "aws s3 cp output-qemu/${local.output_filename}.qcow2 s3://${var.s3_bucket}/$FILENAME",
            "echo \"Successfully uploaded to s3://${var.s3_bucket}/$FILENAME\""
        ]
    }
}