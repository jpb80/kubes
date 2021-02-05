export SHELL := /bin/bash

INFRA=infrastructure
TEMPLATE=template.yaml

AWS_ACCOUNTID=289782891060
AWS_REGION=us-east-1
CFN_TRUST_ROLENAME=admin-cfn-full
DOMAIN=yoorb.com
AWS_REGION_ZONES=us-east-1d
APP=kops

kops-create-cluster kops-edit-cluster kops-update-cluster kops-delete-cluster: export NAME=k8s.${DOMAIN}

kops-create-cluster kops-edit-cluster kops-update-cluster kops-delete-cluster: export KOPS_STATE_STORE=s3://kops-state-store-${AWS_ACCOUNTID}-${AWS_REGION}

kops-create-cluster kops-edit-cluster kops-update-cluster kops-delete-cluster: key=$(aws --profile kops configure get aws_access_key_id); export AWS_ACCESS_KEY_ID=$key

kops-create-cluster kops-edit-cluster kops-update-cluster kops-delete-cluster: secret=$(aws --profile kops configure get aws_secret_access_key); export AWS_SECRET_ACCESS_KEY=$secret

HELP_REGEX:=^(.+): .*\#\# (.*)

CACHE_DIR := .cache
.PHONY: help
help: ## Show this help message.
	@echo 'Usage:'
	@echo '  make [target] ...'
	@echo
	@echo 'Targets:'
	@egrep "$(HELP_REGEX)" Makefile | sed -E "s/$(HELP_REGEX)/  \1 # \2/" | column -t -c 2 -s '#'

.PHONY: init
init:
	python3 -m venv venv; \
	. venv/bin/activate; \
	pip3 install -r requirements.txt; \
	aws iam create-role --role-name admin-cfn-full --assume-role-policy-document file://admin-cfn-role-policy.json; \
	aws iam attach-role-policy --role-name admin-cfn-full --policy-arn arn:aws:iam::aws:policy/AdministratorAccess 

.PHONY: kops_init
kops_init:
	aws iam create-group --group-name kops; \
	aws iam attach-group-policy --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess --group-name kops; \
	aws iam attach-group-policy --policy-arn arn:aws:iam::aws:policy/AmazonRoute53FullAccess --group-name kops; \
	aws iam attach-group-policy --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess --group-name kops; \
	aws iam attach-group-policy --policy-arn arn:aws:iam::aws:policy/IAMFullAccess --group-name kops; \
	aws iam attach-group-policy --policy-arn arn:aws:iam::aws:policy/AmazonVPCFullAccess --group-name kops; \
	aws iam create-user --user-name kops; \
	aws iam add-user-to-group --user-name kops --group-name kops; \
	aws iam create-access-key --user-name kops >> aws_kops_secret.json

.PHONY: deploy-stack-cfn
deploy-stack-cfn:
	. venv/bin/activate; \
	cfn-lint ${INFRA}/cloudformation/${TEMPLATE}; \
	aws cloudformation deploy \
		--template-file ${INFRA}/cloudformation/${TEMPLATE} \
		--stack-name cloudformation \
		--capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
		--role-arn arn:aws:iam::${AWS_ACCOUNTID}:role/admin-cfn-full

.PHONY: deploy-stack-storage
deploy-stack-storage:
	. venv/bin/activate; \
	cfn-lint ${INFRA}/storage/${TEMPLATE}; \
	aws cloudformation deploy \
		--template-file ${INFRA}/storage/${TEMPLATE} \
		--stack-name storage-${APP} \
		--capabilities CAPABILITY_IAM \
		--s3-bucket cfn-template-${AWS_ACCOUNTID}-${AWS_REGION} \
		--role-arn arn:aws:iam::${AWS_ACCOUNTID}:role/cfn-deploy-stacks

.PHONY: deploy-stack-network
deploy-stack-network:
	. venv/bin/activate; \
	cfn-lint ${INFRA}/network/${TEMPLATE}; \
	aws cloudformation deploy \
		--template-file ${INFRA}/network/${TEMPLATE} \
		--stack-name network \
		--capabilities CAPABILITY_IAM \
		--s3-bucket cfn-template-${AWS_ACCOUNTID}-${AWS_REGION} \
		--role-arn arn:aws:iam::${AWS_ACCOUNTID}:role/cfn-deploy-stacks

.PHONY: kops-create-private-cluster
kops-create-private-cluster:
	kops create cluster \
		${NAME} \
		--zones "${AWS_REGION_ZONES}" \
	   	--master-zones "${AWS_REGION_ZONES}" \
	    	--networking calico \
	    	--topology private \
	    	--node-count 1 \
	    	--node-size t2.small \
	    	--master-size t2.small \
		--state ${KOPS_STATE_STORE} \
	    	--vpc vpc-2bd16c53 \
		-v10 \
	    	-o yaml > ${NAME}.yaml

.PHONY: kops-create-public-cluster
kops-create-public-cluster:
	kops create cluster \
		${NAME} \
		--zones "${AWS_REGION_ZONES}" \
	   	--master-zones "${AWS_REGION_ZONES}" \
	    	--networking calico \
	    	--topology public \
	    	--node-count 1 \
	    	--node-size t2.small \
	    	--master-size t2.small \
		--state ${KOPS_STATE_STORE} \
	    	--vpc vpc-2bd16c53 \
		-v10 \
	    	-o yaml > ${NAME}.yaml

.PHONY: kops-edit-cluster
kops-edit-cluster:
	kops edit cluster ${NAME}

.PHONY: kops-edit-nodes
kops-edit-nodes:
	kops edit ig ${NAME} --state=${KOPS_STATE_STORE} nodes

.PHONY: kops-update-cluster
kops-update-cluster:
	kops update cluster ${NAME} --yes -v10

.PHONY: kops-upgrad-cluster
kops-upgrade-cluster:
	kops upgrade cluster ${NAME} --yes -v10

.PHONY: kops-delete-cluster
kops-delete-cluster:
	kops delete cluster ${NAME} --yes

.PHONY: kops-create-secret
kops-create-secret:
	kops create secret --name ${NAME} sshpublickey admin -i ~/.ssh/id_rsa.pub

.PHONY: deploy-all-stacks
deploy-all-stacks: deploy-stack-cfn deploy-stack-storage deploy-stack-network

.PHONY: install
install: deploy-all-stacks
