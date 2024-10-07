# https://hub.docker.com/_/fedora
FROM fedora:38

# RUN dnf install -y dnf-plugins-core
# RUN dnf config-manager --add-repo https://rpm.releases.hashicorp.com/fedora/hashicorp.repo

# add google cloud cli repo
RUN tee -a /etc/yum.repos.d/google-cloud-sdk.repo << EOM
[google-cloud-cli]
name=Google Cloud CLI
baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el9-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOM


# update and install OS packages
RUN dnf -y update && dnf -y groupinstall "Development Tools" && \
    dnf -y install \
    python3-pip \
    python3-devel \
    libffi-devel \
    oniguruma-devel \
    gcc \
    wget \
    vim \
    unzip \
    curl \
    git \
    google-cloud-cli
    # packer

# install requirements
COPY requirements.txt requirements.txt
RUN pip3 install -r requirements.txt

# configure user and sudo
RUN useradd vscode
# permission to vscode user
# RUN mkdir -p /workspaces && chown -R vscode:vscode /workspaces
RUN sudo sed -e 's/^%wheel/#%wheel/g' -e 's/^# %wheel/%wheel/g' \
  -i /etc/sudoers && \
  usermod -aG wheel vscode

# # instruqt cli install
# RUN curl -L https://github.com/instruqt/cli/releases/download/2038-91f9762/instruqt-linux-2038-91f9762.zip -o /tmp/instruqt.zip
# RUN unzip /tmp/instruqt.zip
# # RUN /tmp/instruqt update
# RUN cp instruqt /usr/local/bin
# RUN chmod +x /usr/local/bin/instruqt
# RUN instruqt update