pipeline {
  agent any

  environment {
    REGISTRY = "${env.REGISTRY ?: 'ghcr.io'}"
    IMAGE_REPO = "${env.IMAGE_REPO ?: 'ghcr.io/YOUR_GH_USER/data-cleaner'}"
    IMAGE_TAG = "${env.BUILD_NUMBER}"
    DOCKER_BUILDKIT = "1"
  }

  stages {
    stage('Checkout') {
      steps { checkout scm }
    }

    stage('Unit Tests') {
        steps {
            sh '''
            docker run --rm -v "$PWD":/app -w /app python:3.11-bullseye bash -lc "
                python -m venv .venv && . .venv/bin/activate &&
                pip install -r app/requirements.txt pytest &&
                pytest -q
            "
            '''
        }
        post { always { sh 'rm -rf .venv' } }
        }


    stage('Build Image') {
      steps {
        sh '''
          docker build -t ${IMAGE_REPO}:${IMAGE_TAG} .
        '''
      }
    }

    stage('Login & Push') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'REGISTRY_CREDS', usernameVariable: 'USER', passwordVariable: 'TOKEN')]) {
          sh '''
            echo "${TOKEN}" | docker login ${REGISTRY} -u "${USER}" --password-stdin
            docker push ${IMAGE_REPO}:${IMAGE_TAG}
          '''
        }
      }
    }

    stage('Deploy to K8s') {
      steps {
        sh '''
          # Render image tag into manifests and apply
          mkdir -p build/k8s
          sed "s/{{IMAGE_TAG}}/${IMAGE_TAG}/g" k8s/deployment.yaml > build/k8s/deployment.yaml

          kubectl apply -f k8s/namespace.yaml
          kubectl -n ${KUBE_NAMESPACE} apply -f build/k8s/deployment.yaml
          kubectl -n ${KUBE_NAMESPACE} apply -f k8s/service.yaml

          kubectl -n ${KUBE_NAMESPACE} rollout status deploy/data-cleaner --timeout=120s
        '''
      }
    }
  }

  post {
    success {
      echo "Deployed ${IMAGE_REPO}:${IMAGE_TAG}"
    }
    failure {
      echo "Pipeline failed."
    }
  }
}
