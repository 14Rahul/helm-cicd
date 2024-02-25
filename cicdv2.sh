#!/bin/bash

REGION=$1
SERVICE=$2
BRANCH=$3
ENV=$4
IMAGE_TAG="$ENV-latest"
REPO_HOME=$5
DOCKER_PATH=$6
SHA=$7
COMMIT="commit-$SHA"
NAMESPACE=$8
FREEZE=$9
#PAT=${10}
REPO_NAME=${10}

echo "Region: $REGION"
echo "SERVICE: $SERVICE"
echo "BRANCH: $BRANCH"
echo "ENV: $ENV"
echo "IMAGE_TAG: $IMAGE_TAG"
echo "REPO_HOME: $REPO_HOME"
echo "DOCKER_PATH: $DOCKER_PATH"
echo "SHA: $SHA"
echo "COMMIT: $COMMIT"
echo "NAMESPACE: $NAMESPACE"
echo "FREEZE: $FREEZE"
#echo "PAT: $PAT"
echo "REPO_NAME: $REPO_NAME"

set -e

if [ -z "$REGION" ] || [ -z "$SERVICE" ] || [ -z "$BRANCH" ] || [ -z "$ENV" ] || [ -z "$REPO_HOME" ] || [ -z "$DOCKER_PATH" ] || [ -z "$SHA" ] || [ -z "$NAMESPACE" ] || [ -z "$REPO_NAME" ]; then
    echo "Missing required parameters. Exiting."
    exit 1
fi

# Function to log errors and exit
log_and_exit() {
    echo "Error: $1"
    echo "Exiting."
    exit 1
}

select_eks_cluster() {
    if [ "$ENV" == "dev" ] || [ "$ENV" == "qa" ]; then
        echo "Logging in to Dev EKS in Mumbai Region"
        aws eks update-kubeconfig --name Github-Runner-k8s --region ap-south-1 --role-arn arn:aws:iam::532968567499:role/Github-Runner-k8s-admin
    elif [ "$ENV" == "prod" ]; then
        if [ "$REGION" == "ap-south-1" ]; then
            echo "Logging in Prod EKS in US Region"
            aws eks update-kubeconfig --name Github-Runner-k8s --region ap-south-1 --role-arn arn:aws:iam::532968567499:role/Github-Runner-k8s-admin
        elif [ "$REGION" == "ca-central-1" ]; then
            echo "Logging in Prod EKS in CA Region"
            aws eks update-kubeconfig --name CaEKSInf1 --region ca-central-1 --role-arn arn:aws:iam::532968567499:role/admin-role-CaEKSInf1
        elif [ "$REGION" == "eu-west-2" ]; then
            echo "Logging in Prod EKS in UK Region"
            aws eks update-kubeconfig --name LoEKSInf1 --region eu-west-2 --role-arn arn:aws:iam::532968567499:role/admin-role-LoEKSInf1
        fi
    elif [ "$ENV" == "pci" ]; then
        echo "Logging in to PCI EKS in US Region"
        aws eks update-kubeconfig --name OhEKSIntApiPci --region ap-south-1 --role-arn arn:aws:iam::532968567499:role/admin-role-OhEKSIntApiPci
    else
        echo "Invalid Environment"
        exit 1
    fi
}

check_main_branch(){
  #current_branch=$(git symbolic-ref --short HEAD 2>/dev/null)
  # Compare the current branch with "main/master"
  if [ "$BRANCH" == "main" ] || [ "$BRANCH" == "master" ]; then
      echo "The current branch is $BRANCH. Proceeding with image build"
  else
      echo "The current branch is not main/master. Exiting."
      exit 1
  fi
}

build_and_push_image() {

  ecr_repo_uri="532968567499.dkr.ecr.$REGION.amazonaws.com/$SERVICE"
  
  cd "$REPO_HOME/repo/" || log_and_exit "Failed to change to repo directory"
  echo "Logging in to AWS ECR"
  #echo 'aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "532968567499.dkr.ecr.$REGION.amazonaws.com"'
  #aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "532968567499.dkr.ecr.$REGION.amazonaws.com"
  aws ecr get-login-password --region "ap-south-1" | docker login --username AWS--password-stdin "532968567499.dkr.ecr.ap-south-1.amazonaws.com"
  aws codeartifact login --tool pip --repository propy --domain prodigaltech --domain-owner 532968567499 --region ap-south-1
#  echo "Pulling the latest image from ECR..."
#  docker pull "$ecr_repo_uri:$IMAGE_TAG" || log_and_exit "Failed to pull image"

  echo "Building and tagging the Docker image..."
  #docker buildx build --cache-from "$ecr_repo_uri:$IMAGE_TAG" --cache-to type=inline "$ecr_repo_name:$commit_sha" -t "$ecr_repo_name:$IMAGE_TAG" "$REPO_PATH" 
  docker build --build-arg DEPLOYMENT_ENV=$ENV  -t "$ecr_repo_uri:$IMAGE_TAG" -f "$REPO_HOME/repo/$DOCKER_PATH/Dockerfile" . || log_and_exit "Failed to build image"

  echo "Pushing the Docker image to ECR..."
  docker push "$ecr_repo_uri:$IMAGE_TAG" || log_and_exit "Failed to push image"
#  docker push "$ecr_repo_uri:$COMMIT" || log_and_exit "Failed to push image"
  #docker push "$ecr_repo_uri:latest" || log_and_exit "Failed to push image"

}

deploy() {
    echo "Deploying $SERVICE to $ENV"
    cd "$REPO_HOME/aws-code/helm"
    helm upgrade --install "$SERVICE" golden-helm-chart -f "$SERVICE/$REGION/$ENV.yaml" --set deployment.image.tag="$IMAGE_TAG" -n "$NAMESPACE" --create-namespace --wait --timeout 150s || log_and_exit "Helm upgrade failed"
}

deploy_only() {
    echo "Deploying $SERVICE to $ENV"
    cd "$REPO_HOME/aws-code/helm"
    helm upgrade --install "$SERVICE" golden-helm-chart -f "$SERVICE/$REGION/$ENV.yaml" --set deployment.image.tag="$IMAGE_TAG" -n "$NAMESPACE" --create-namespace --force --wait --timeout 300s || log_and_exit "Helm upgrade failed"
}

cleanup() {
    echo "Cleaning up the Repository from runner"
    rm -rf $REPO_HOME
}

select_eks_cluster

if [ "$ENV" == "prod" ] || [ "$ENV" == "pci" ]; then
    check_main_branch || log_and_exit "Failed to check main branch. Exiting."
fi
if [ "$SERVICE" == "bifrost" ] || [ "$SERVICE" == "bifrost-reports" ] || [ "$SERVICE" == "bifrost-aggregated-redaction" ]; then
    build_and_push_image || log_and_exit "Failed to build and push the image. Exiting."
    #cleanup
elif [ "$SERVICE" == "summary-blocks-reason-for-call" ] || [ "$SERVICE" == "sentiment-backend" ]; then
    deploy_only || log_and_exit "Failed to deploy. Exiting."
else
    build_and_push_image || log_and_exit "Failed to build and push the image. Exiting."
    deploy || log_and_exit "Failed to deploy. Exiting."
    #cleanup
fi
if [ "$FREEZE" == true ] && [ "$BRANCH" == "main" ]; then
    if [ "$ENV" == "prod" ] || [ "$ENV" == "pci" ]; then
        cd "$REPO_HOME/repo"
        echo $PAT | gh auth login --with-token
        git remote set-url origin https://prodigal-tech:"$PAT"@github.com/"$REPO_NAME".git || log_and_exit "Error Setting Remote. Exiting."
        export NEW_BRANCH_NAME="requirement_freezed_$(date +'%Y%m%d%H%M%S')"
        git checkout -b $NEW_BRANCH_NAME
        echo "Freezing and adding current requirement.txt to Github"
        docker create --name freeze_container "$ecr_repo_uri:$IMAGE_TAG" sh
        docker cp freeze_container:/app/requirements_freezed.txt "$REPO_HOME/repo/$DOCKER_PATH/"
        docker rm -f freeze_container
        
        git add requirements_freezed.txt || log_and_exit "Failed to add requirements_freezed.txt. Exiting."
        git config --global user.name "CICD Bot"
        git config --global user.email "devsecops@prodigaltech.com"
        git commit --allow-empty -m "adding the requirements_freezed.txt and releasing a new docker image" || log_and_exit "Failed to commit. Exiting."
        git push -u origin $NEW_BRANCH_NAME || log_and_exit "Failed to Push to New Branch. Exiting."
        gh pr create -R $REPO_NAME -B main -f || log_and_exit "Failed to Create PR. Exiting."
        gh pr merge --auto --delete-branch -s || log_and_exit "Failed to Merge PR. Exiting."
    fi
fi

echo "Success"
