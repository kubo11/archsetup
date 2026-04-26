#!/bin/sh

WORK_DIR=/tmp/postinstall

echo "Creating work dir..."
mkdir -p $WORK_DIR
cd $WORK_DIR

echo "Creating virtual environment..."
python3 -m venv venv
source venv/bin/activate

echo "Installing ansible..."
pip3 install ansible

echo "Cloning archsetup repository..."
git clone https://github.com/kubo11/archsetup.git
cd archsetup

echo "Running ansible..."
ansible-playbook -i localhost setup.yml