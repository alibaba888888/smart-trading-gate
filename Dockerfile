# syntax=docker/dockerfile:1
# trading-web 容器镜像
# 多阶段构建：Maven 构建 -> JRE 运行

# ===== 1. 构建阶段 =====
FROM maven:3.9-eclipse-temurin-21 AS builder
WORKDIR /build

# 先拷贝 pom，利用层缓存预下载依赖
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 mvn -B -q dependency:go-offline

# 拷贝源码并打包
COPY src ./src
RUN --mount=type=cache,target=/root/.m2 mvn -B -DskipTests package \
 && cp target/*.jar /build/app.jar

# ===== 2. 运行阶段 =====
FROM eclipse-temurin:21-jre
WORKDIR /app

# 非 root 用户运行
RUN useradd -m -u 10001 appuser && chown -R appuser:appuser /app
USER appuser

COPY --from=builder /build/app.jar app.jar

# 日志目录（运行时可挂载 volume 持久化）
RUN mkdir -p logs && chown -R appuser:appuser logs
VOLUME ["/app/logs"]

# 对外展示站点端口
EXPOSE 8085

# 运行时配置通过环境变量覆盖（profile / 数据库 / 连接池 等）
ENV SPRING_PROFILES_ACTIVE=prod \
    JAVA_OPTS="-XX:MaxRAMPercentage=75.0 -XX:+UseZGC -XX:+ExitOnOutOfMemoryError"

ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar app.jar"]
