// =============================================================================
//  mall-admin-web 前端 CI/CD 流水线
//
//  Jenkins → 镜像构建（多阶段，内含 npm build）→ 推送 Harbor → K8s 滚动更新
//
//  ── 和后端流水线的区别 ──────────────────────────────────────────────────
//  后端：mvn package → docker build → push → deploy          （4 步）
//  前端：docker build（多阶段里跑 npm ci + npm run build）→ push → deploy
//        ↑ 没有独立的"Node 构建"阶段，因为构建环境被封装进 Dockerfile 了
//          这正是多阶段构建的好处：Jenkins 机器上不需要装 Node
//
//  ── 为什么锁 node:14 ────────────────────────────────────────────────────
//  项目用 webpack 3.6（2017 年）。Node 17+ 换成 OpenSSL 3 之后 webpack 3/4
//  会直接报 ERR_OSSL_EVP_UNSUPPORTED。版本锁在 Dockerfile 里，不依赖宿主机。
//
//  ── 前提 ────────────────────────────────────────────────────────────────
//  1) jenkins 用户已加入 docker 组
//  2) 本机有 kubectl + /var/lib/jenkins/.kube/config
//  3) Jenkins 凭据 harbor-passport（用户名/密码）存在
//  4) Jenkins job 的 Branch Specifier 要写 */dev-v2（这个仓库不是 master）
//
//  ── 关于 latest 标签 ────────────────────────────────────────────────────
//  推两个 tag：<sha>-<buildno>（Deployment 用）+ latest（手工拉取用）
//  Deployment 里不要用 latest，原因见后端 Jenkinsfile 的详细说明
// =============================================================================

pipeline {
  agent any

  options {
    timestamps()
    skipDefaultCheckout(true)
    disableConcurrentBuilds()
    timeout(time: 120, unit: 'MINUTES')     // 首次 npm ci 很慢，给足时间
    buildDiscarder(logRotator(numToKeepStr: '20'))
  }

  parameters {
    string(name: 'GIT_BRANCH',     defaultValue: 'dev-v2',              description: '源码分支')
    string(name: 'REGISTRY',       defaultValue: '192.168.203.120:80',  description: 'Harbor 地址')
    string(name: 'HARBOR_PROJECT', defaultValue: 'mall',                description: 'Harbor 项目名')
    string(name: 'NAMESPACE',      defaultValue: 'mall',                description: 'K8s 命名空间')
    string(name: 'DEPLOYMENT',     defaultValue: 'mall-admin-web',      description: '要更新的 Deployment 名')
    booleanParam(name: 'DO_DEPLOY', defaultValue: true,                 description: '是否执行 K8s 滚动更新')
  }

  environment {
    APP            = 'mall-admin-web'
    REGISTRY_ADDR  = "${params.REGISTRY}"
    HARBOR_PROJECT = "${params.HARBOR_PROJECT}"
    NAMESPACE      = "${params.NAMESPACE}"
    DEPLOYMENT     = "${params.DEPLOYMENT}"
  }

  stages {

    // ------------------------------------------------------------- 1 ------
    stage('拉取代码') {
      steps {
        checkout([$class: 'GitSCM',
          branches: [[name: "*/${params.GIT_BRANCH}"]],
          userRemoteConfigs: [[
            url: 'git@github.com:moyu-777/mall-admin-web.git',
            credentialsId: 'github-pvt'
          ]],
          extensions: [
            [$class: 'CleanCheckout']
          ]
        ])
      }
    }

    // ------------------------------------------------------------- 2 ------
    stage('计算镜像 tag') {
      steps {
        script {
          def sha   = sh(script: 'git rev-parse --short=7 HEAD', returnStdout: true).trim()
          def dirty = sh(script: 'git status --porcelain | head -1 || true', returnStdout: true).trim()
          env.IMAGE_TAG  = sha + (dirty ? '-dirty' : '') + '-' + env.BUILD_NUMBER
          env.FULL_IMAGE = "${params.REGISTRY}/${params.HARBOR_PROJECT}/${env.APP}:${env.IMAGE_TAG}"
          echo "代码版本 : ${sha}"
          echo "完整镜像 : ${env.FULL_IMAGE}"
        }
      }
    }

    // ------------------------------------------------------------- 3 ------
    stage('构建镜像') {
      steps {
        // 多阶段构建：Node14 编译 + nginx 打包，一条命令搞定
        // 注意：这台机器没有 buildx，用的是 legacy builder（会打一条 DEPRECATED
        // 警告，不影响构建，只是用不了 --mount=type=cache）
        sh "docker build -t $FULL_IMAGE ."
        sh "docker images --format '{{.Repository}}:{{.Tag}}  {{.Size}}' | grep $APP || true"
        echo '--- 确认产物里 index.html 存在 ---'
        sh "docker run --rm --entrypoint sh $FULL_IMAGE -c 'ls -la /usr/share/nginx/html/index.html'"
      }
    }

    // ------------------------------------------------------------- 4 ------
    stage('推送 Harbor') {
      steps {
        withCredentials([usernamePassword(
            credentialsId: 'harbor-passport',
            usernameVariable: 'HARBOR_USER',
            passwordVariable: 'HARBOR_PASS')]) {
          sh '''
            set -e
            echo "$HARBOR_PASS" | docker login "$REGISTRY_ADDR" -u "$HARBOR_USER" --password-stdin
            docker push "$FULL_IMAGE"

            LATEST_IMAGE="${REGISTRY_ADDR}/${HARBOR_PROJECT}/${APP}:latest"
            docker tag "$FULL_IMAGE" "$LATEST_IMAGE"
            docker push "$LATEST_IMAGE"

            echo "已推送："
            echo "  $FULL_IMAGE   (Deployment 用这个)"
            echo "  $LATEST_IMAGE (仅方便手工拉取)"

            docker logout "$REGISTRY_ADDR" || true
          '''
        }
      }
    }

    // ------------------------------------------------------------- 5 ------
    stage('K8s 滚动更新') {
      when { expression { return params.DO_DEPLOY } }
      steps {
        sh '''
          set -e

          if ! kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT" >/dev/null 2>&1; then
            echo "=============================================="
            echo " Deployment/$DEPLOYMENT 不存在。"
            echo " 按约定，首次创建是手动做的："
            echo "   kubectl apply -f mall-k8s/13-mall-admin-web.yaml"
            echo " 本流水线只做「更新镜像」。"
            echo "=============================================="
            exit 1
          fi

          echo "=== 更新前 ==="
          kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT" \
            -o jsonpath='{.spec.template.spec.containers[0].image}'; echo

          kubectl -n "$NAMESPACE" set image deployment/"$DEPLOYMENT" "$DEPLOYMENT"="$FULL_IMAGE"

          echo "=== 等待滚动更新完成（最长 5 分钟）==="
          kubectl -n "$NAMESPACE" rollout status deployment/"$DEPLOYMENT" --timeout=300s

          echo "=== 更新后 ==="
          kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT" \
            -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
          kubectl -n "$NAMESPACE" get pods -l app="$DEPLOYMENT" -o wide
        '''
        script { env.DEPLOY_DONE = 'true' }
      }
    }
  }

  post {
    success {
      echo "✅ ${params.DEPLOYMENT} 已更新到 ${env.FULL_IMAGE}"
    }
    failure {
      script {
        if (env.DEPLOY_DONE == 'true' && params.DO_DEPLOY) {
          echo "⚠️  部署后失败，回滚到上一个版本"
          sh "kubectl -n ${params.NAMESPACE} rollout undo deployment/${params.DEPLOYMENT} || true"
        }
      }
    }
    always {
      sh 'docker logout $REGISTRY_ADDR 2>/dev/null || true'
    }
  }
}
