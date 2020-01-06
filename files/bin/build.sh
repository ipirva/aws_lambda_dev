#!/bin/bash
# 05 2019
# Ionut Pirva
# Build lambda function
# Update AWS lambda w/ Terraform
# Use Drone CD platform and integration with Git (Gogs)
# Push the AWS Lambda Zip to a local DAV server for backup
# ENV variables set from Drone

set -o errexit
set -o nounset
set -o pipefail

export LC_ALL=en_US.utf-8
export LANG=en_US.utf-8

GIT_PROTOCOL="ssh"
GIT_USER_EMAIL="EMAILADDRESS"
GIT_USER_NAME="AWS Lambda"

if [ -z $GIT_PORT_ENV ]
then
    GIT_PORT=10022
else
    GIT_PORT=$GIT_PORT_ENV
fi

timestamp=$(date +"%Y-%m-%d_%H-%M-%S")

# check the ENV variables set from drone
if [ -z "$DRONE_REPO_NAME" ]
then
    echo -e "Repository name not found on env DRONE_REPO_NAME\n"
    exit 1    
fi

if [ -z "$DRONE_REPO_NAMESPACE" ]
then
    echo -e "Git namespace not found on env DRONE_REPO_NAMESPACE\n"
    exit 1    
fi

if [ -z "$DRONE_GIT_SSH_URL" ]
then
    echo -e "Git SSH URL not found on env DRONE_GIT_SSH_URL\n"
    exit 1    
fi

if [ -z "$DRONE_REPO_BRANCH" ]
then
    echo -e "Git repo branch not found on env DRONE_REPO_BRANCH\n"
    exit 1
fi

if [ -z "$DAV_SERVER_NAME_ENV" ]
then
    echo -e "DAV server address not found on env DAV_SERVER_NAME_ENV\n"
    exit 1
fi

if [ -z "$USERNAME_DAV_ENV" ]
then
    echo -e "DAV username not found on env USERNAME_DAV_ENV\n"
    exit 1
fi

if [ -z "$PASSWORD_DAV_ENV" ]
then
    echo -e "DAV password not found on env PASSWORD_DAV_ENV\n"
    exit 1
fi

if [ -n "$PYTHON_VER_MAJ_ENV" ]
then
    pip="pip"$PYTHON_VER_MAJ_ENV
else
    pip="pip3"
fi
# buil git host e.g. gogs.local
GIT_HOST=$(echo $DRONE_GIT_SSH_URL | awk '{split($0, a, "@"); print a[2]}' | awk '{split($0, a, ":"); print a[1]}')
# prepare the SSH environment
sed -i "s|{GIT_PORT}|${GIT_PORT_ENV}|g" /root/.ssh/config
sed -i "s|{GIT_HOST}|${GIT_HOST}|g" /root/.ssh/config
sed -i "s|{GIT_USER}|${DRONE_REPO_NAMESPACE}|g" /root/.ssh/config
# build git url e.g. git@gogs.local
GIT_URL=$(echo $DRONE_GIT_SSH_URL | cut -d: -f1)
# build git address e.g. ssh://git@gogs.local
GIT_ADDRESS=$GIT_PROTOCOL"://"$GIT_URL":"$GIT_PORT
echo -e "Git address is: "$GIT_ADDRESS"\n"

MODULES=/tmp/modules
BIN=/tmp/bin
FOLDER=/tmp/$DRONE_REPO_NAME
ZIPPKGFILE=$DRONE_REPO_NAME".zip"
ZIPPKG=/tmp/$ZIPPKGFILE
TERRAFORMPLAN=terraform.plan
TERRAFORMSTATE=terraform.tfstate
TERRAFORMVARSTEMP=terraform.in.tfvars
TERRAFORMVARS=terraform.tfvars

mkdir -p $MODULES
mkdir -p $BIN
mkdir -p $FOLDER

cd $FOLDER && \
echo -e "Working folder is: "$FOLDER"\n" && \
echo -e "Fetching origin repo: "$GIT_ADDRESS/$DRONE_REPO_NAMESPACE/$DRONE_REPO_NAME".git - branch: "$DRONE_REPO_BRANCH"\n"

git init
git config --global user.email $GIT_USER_EMAIL
git config --global user.name $GIT_USER_NAME
git remote add -f origin $GIT_ADDRESS/$DRONE_REPO_NAMESPACE/$DRONE_REPO_NAME".git"
git pull origin $DRONE_REPO_BRANCH

echo -e "Build the PIP requirements.txt and install PIP modules.\n"

if [ -s "requirements.txt" ]; then
	echo -e "PIP requirements.txt exists - to be used.\n"
	$pip install -r requirements.txt --target $MODULES -U --install-option="--install-scripts=/tmp/bin"
else
	echo -e "PIP requirements.txt does not exist - to be created.\n" && \
	if [ -s "requirements.in" ]; then
		pip-compile requirements.in -o requirements.txt && \
		$pip install -r requirements.txt --target $MODULES -U --no-deps --install-option="--install-scripts=/tmp/bin" && \
		# add requirements.txt to git
		echo -e "Add PIP requirements.txt to Git\n" && \
		git add requirements.txt
	else
		echo -e "PIP requirements.in does not exist or is empty.\n"
	fi
fi

cd $MODULES
find . | grep -E "(__pycache__|\.pyc|\.pyo|\.*\.dist-info|\.*\.egg-info$)" | xargs rm -rf || true
find . -maxdepth 1 -mindepth 1 | grep -E "(pip.*|setuptools.*|wheel.*|pkg_resources.*|easy_install.py)" | xargs rm -rf || true
#find . -maxdepth 1 -mindepth 1 | grep -E "(__pycache__|\.pyc|\.pyo|\.py|\.*\.egg-info$)" | xargs rm -rf || true
find $MODULES -maxdepth 1 -mindepth 1 -type d -exec mv '{}' $FOLDER \; || true
find $MODULES -maxdepth 1 -mindepth 1 -type f -exec mv '{}' $FOLDER \; || true

echo -e "Create the ZIP Lmabda package.\n"
# create the zip package
cd $FOLDER && zip -r $ZIPPKG . -x "*/.*" -x "requirements.*" -x "terraform.*"
echo -e "Upload ZIP lambda package to DAV\n"
# upload the package to DAV
curl -L -u $USERNAME_DAV_ENV:$PASSWORD_DAV_ENV -X PUT -T $ZIPPKG $DAV_SERVER_NAME_ENV/$DRONE_REPO_NAME/

# skip terraform if the file terraform.no is present
if [ -f "terraform.no" ]; then echo -e "File terraform.no found - Terraform skipped.\n" && exit 0; fi

# handle terraform
echo -e "Handle Terraform.\n"
# handle Terraform
# push to Git the Terraform state and tfvars files - add [CI SKIP] to the Git commit comment to avoid running Drone
cd $FOLDER && cp $ZIPPKG .
if [ -s "$TERRAFORMVARSTEMP" ]; then
    echo -e "I found $TERRAFORMVARSTEMP - I am rewriting the $TERRAFORMVARS file\n" && \
    cp $TERRAFORMVARSTEMP $TERRAFORMVARS && \
    sed -i "s|{LAMBDANAME}|${DRONE_REPO_NAME}|g" $TERRAFORMVARS && \
    sed -i "s|{ZIPPKGFILE}|${ZIPPKGFILE}|g" $TERRAFORMVARS
fi
terraform init && \
terraform import aws_lambda_function.lambda ${DRONE_REPO_NAME} || true && \
terraform plan -out $TERRAFORMPLAN && terraform apply -auto-approve $TERRAFORMPLAN && \
echo -e "Push to git terraform state and tfvars files\n" && \
git add $TERRAFORMSTATE && git add $TERRAFORMVARS && git commit -m "Add terraform state [CI SKIP]" && git push origin master
