# 阶段 1：安装依赖
FROM node:22-alpine AS deps
WORKDIR /app
ENV CI=true
RUN corepack enable

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile

# 阶段 2：编译指定微服务并裁剪开发依赖
FROM node:22-alpine AS builder
WORKDIR /app
ENV CI=true
RUN corepack enable

ARG APP_NAME=auth
COPY --from=deps /app/node_modules ./node_modules
COPY . .

RUN pnpm nest build ${APP_NAME} && pnpm prune --prod

# 阶段 3：生产运行镜像
FROM node:22-alpine AS runner
WORKDIR /app

ARG APP_NAME=auth
ENV NODE_ENV=production
ENV APP_NAME=${APP_NAME}

COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist/apps/${APP_NAME} ./dist/apps/${APP_NAME}
# 拷贝邮件 Handlebars 模板，确保 SWC 编译后仍能读取静态模板文件
COPY --from=builder /app/lib/common/mail/templates ./lib/common/mail/templates

EXPOSE 3000 3031

CMD ["sh", "-c", "node dist/apps/${APP_NAME}/apps/${APP_NAME}/src/main.js"]

