#!/bin/bash

echo "Update sha256 checksum file for AWS script"

cd "AWS/EC2"
sha256sum ec2-install.sh > ec2-install.sh.sha256