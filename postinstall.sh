#!/bin/sh

WORK_DIR=/tmp/postinstall

mkdir -p $WORK_DIR

cd $WORK_DIR

python3 -m venv venv

source venv/bin/activate

pip3 install ansible

git clone https://github.com/kubo11/archsetup.git

cd archsetup

ansible-playbook -i localhost setup.yml