# =============================================================================
#  mall-admin-web —— Vue2 + webpack3 前端
#  多阶段构建：Node 14 编译 → nginx 托管产物
#
#  为什么锁 Node 18（两个约束夹出来的版本）：
#    ① package-lock.json 是 lockfileVersion 3 —— 由 npm 9 生成，
#       只有 Node 18+ 自带的 npm 才认得。Node 14/16 的 npm 6/8 读不了，
#       会报 "Cannot read property 'axios' of undefined"。
#    ② 项目用 webpack 3.6（2017 年），它内部用 md4 做哈希，而 Node 17+ 换成
#       OpenSSL 3 后 md4 被移出默认提供者，会报
#         Error: error:0308010C:digital envelope routines::unsupported
#       解法是加 NODE_OPTIONS=--openssl-legacy-provider 把旧算法放回来。
#    两条合起来 → Node 18 + --openssl-legacy-provider 是唯一稳的组合。
#    版本锁在 Dockerfile 里就跟着代码走，不用管宿主机装了什么 Node。
#
#  构建：
#    docker build -t 192.168.203.120:80/mall/mall-admin-web:<tag> .
# =============================================================================

# ---------------------------------------------------------------- 构建阶段 --
FROM node:18-bullseye AS builder
WORKDIR /app

# 换国内 npm 源（不换会慢到无法接受）
RUN npm config set registry https://registry.npmmirror.com

# ★ 先只拷依赖清单：package*.json 不变时命中层缓存，整个 npm ci 直接跳过
#   （这一步通常是全流程里最耗时的）
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund || npm install --no-audit --no-fund

# 再拷源码
COPY . .

# --openssl-legacy-provider : 让 webpack 3 能用到 md4（Node 17+ 必需）
# --max-old-space-size      : 限制 Node 堆，别把机器内存打爆
ENV NODE_OPTIONS="--openssl-legacy-provider --max-old-space-size=2048"
RUN npm run build

# 产物自检：index.html 必须存在，否则让构建直接失败，别等到部署才发现
RUN test -f dist/index.html && echo "✅ dist 生成成功" && du -sh dist

# ---------------------------------------------------------------- 运行阶段 --
FROM nginx:1.25-alpine

ENV TZ=Asia/Shanghai
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo "$TZ" > /etc/timezone

COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
