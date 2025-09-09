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

variable "ssh_password" {
    type    = string
    default = null
    description = "SSH password for the rhel user"
    sensitive = true
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
        "-e", "aap_include_eda_controller=${var.aap_include_eda_controller}",
        "-e", "ansible_become_pass=${var.ssh_password}"
    ]

    // Combine arguments into extra_args
    extra_args = concat(local.extra_args_common, local.extra_args_file)
    
    // Output filename with version placeholder
    output_filename = "aap-${local.image_label}-${formatdate("YYYYMMDD", timestamp())}"
}

source "qemu" "rhel9" {
    // Use RHEL 9 qcow2 image downloaded from S3
    iso_url = "file:///home/runner/work/aap-images/aap-images/images/packer/rhel-9-cloud.qcow2"
    iso_checksum = "none"
    
    // Use qcow2 format for direct output
    format = "qcow2"
    disk_image = true
    use_default_display = true
    
    // VM configuration - increased for AAP requirements
    memory = 16384  // Increased to 16GB for AAP requirements
    cpus = 4
    disk_size = "30G"
    
    // Network and SSH configuration - direct user auth
    communicator = "ssh"
    ssh_username = "rhel"
    ssh_password = var.ssh_password
    ssh_timeout = "20m"
    ssh_wait_timeout = "15m"
    ssh_handshake_attempts = 200
    ssh_port = 22
    ssh_host_port_min = 2222
    ssh_host_port_max = 4444
    ssh_keep_alive_interval = "5s"
    ssh_read_write_timeout = "10m"
    
    // Output configuration
    vm_name = "${local.output_filename}.qcow2"
    output_directory = "output-qemu"
    
    // Boot configuration - minimal wait since no cloud-init needed
    boot_wait = "30s"
    boot_command = []
    
    // QEMU specific settings
    qemu_binary = "qemu-system-x86_64"
    machine_type = "pc"
    net_device = "virtio-net"
    disk_interface = "virtio"
    
    // Network configuration for SSH access
    qemuargs = [
        ["-netdev", "user,id=user.0,hostfwd=tcp::{{ .SSHHostPort }}-:22"],
        ["-device", "virtio-net,netdev=user.0"],
        ["-cpu", "Nehalem"],  // Support x86-64-v2 instructions
        ["-serial", "stdio"],  // Get serial output for debugging
        ["-rtc", "base=utc,clock=host"],  // Fix clock issues
        ["-no-hpet"],  // Disable HPET to avoid clock conflicts
        ["-global", "kvm-pit.lost_tick_policy=discard"]  // Improve timing
    ]
    
}

build {
    sources = ["source.qemu.rhel9"]

    // Pre-build debug
    provisioner "shell" {
        inline = ["echo 'Building AAP qcow2 image with components: ${local.image_label}'"]
    }


    // Debug and verify SSH access
    provisioner "shell" {
        inline = [
            "echo 'Current user:'",
            "whoami",
            "echo 'User details:'",
            "id",
            "echo 'SSH connection successful with rhel user!'"
        ]
    }

    // Pre install tasks
    provisioner "ansible" {
        command = "ansible-playbook"
        playbook_file = "${path.root}/../aap/playbooks/pre-install.yml"
        user = "rhel"
        inventory_file_template = "controller ansible_host={{ .Host }} ansible_user={{ .User }} ansible_port={{ .Port }} ansible_ssh_pass=${var.ssh_password}\n"
        use_proxy = false
        extra_arguments = concat(local.extra_args, ["-e", "ansible_ssh_pass=${var.ssh_password}", "-e", "rhel_user_password=${var.ssh_password}"])
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
        destination = "/tmp/aap_version_qemu.txt"
        direction = "download"
    }

    // Platform install
    provisioner "shell" {
        environment_vars = [
            "LC_ALL=C.utf8",
            "LANG=C.utf8",
            "LANGUAGE=en"
        ]
        timeout = "60m"
        inline = [
            "echo 'Starting AAP installation...'",
            "export LC_ALL=C.utf8",
            "export LANG=C.utf8",
            "export LANGUAGE=en",
            "if [ -d /tmp/ansible-automation-platform-containerized-setup ]; then",
            "  cd /tmp/ansible-automation-platform-containerized-setup",
            "  echo 'Found installer directory, starting installation...'",
            "  echo 'Contents of inventory.custom:'",
            "  cat inventory.custom",
            "  echo '--- End of inventory ---'",
            "  ANSIBLE_COLLECTIONS_PATH=/tmp/ansible-automation-platform-containerized-setup/collections ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -vvvv -i inventory.custom ansible.containerized_installer.install",
            "  echo 'AAP installation completed with exit code: $?'",
            "else",
            "  echo 'Error: Directory /tmp/ansible-automation-platform-containerized-setup does not exist.'",
            "  ls -la /tmp",
            "  exit 1",
            "fi"
        ]
    }

    // Post install tasks
    provisioner "ansible" {
        command = "ansible-playbook"
        playbook_file = "${path.root}/../aap/playbooks/post-install.yml"
        user = "rhel"
        inventory_file_template = "controller ansible_host={{ .Host }} ansible_user={{ .User }} ansible_port={{ .Port }} ansible_ssh_pass=${var.ssh_password}\n"
        use_proxy = false
        extra_arguments = concat(local.extra_args, ["-e", "ansible_ssh_pass=${var.ssh_password}"])
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
            "sudo rm -f /home/rhel/.bash_history",
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
            "${var.aap_version != null ? "AAP_VERSION=\"${var.aap_version}\"" : "AAP_VERSION=$(cat /tmp/aap_version_qemu.txt)"}",
            "FILENAME=\"aap-$AAP_VERSION-${local.image_label}-${formatdate("YYYYMMDD", timestamp())}.qcow2\"",
            "aws s3 cp output-qemu/${local.output_filename}.qcow2 s3://${var.s3_bucket}/$FILENAME",
            "echo \"Successfully uploaded to s3://${var.s3_bucket}/$FILENAME\""
        ]
    }
}