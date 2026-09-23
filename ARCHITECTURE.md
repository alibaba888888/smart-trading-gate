# trading-web 架构与部署文档

> 项目代号：`trading-web`（Maven artifactId: `com.trading`）
> 定位：加密货币交易系统的**只读数据展示前端服务**，与 `trading-data-Aanalizer` 共享同一 MySQL 数据库 `trading_db`（前者负责采集/分析/交易，本服务负责对外查询展示）。

---

## 一、项目概述与技术栈

| 维度 | 选型 |
| --- | --- |
| 语言 / JDK | Java 21（启用虚拟线程） |
| 框架 | Spring Boot 4.0.1（`spring-boot-starter-parent`） |
| 构建工具 | Maven（含 `mvnw` / `mvnw.cmd` Wrapper） |
| Web 层 | `spring-boot-starter-webmvc`（Spring MVC） |
| 持久层 | MyBatis（`mybatis-spring-boot-starter` 4.0.0）+ MySQL 驱动 + MariaDB 驱动 |
| 连接池 | HikariCP（自定义 `DataSourceConfig` 手动绑定参数） |
| 前端 | 原生 HTML + 原生 JS + ECharts（无 Vue/React 构建工程），支持 PWA |
| JSON | fastjson `2.0.32` |
| 工具库 | Lombok（provided）、devtools |

入口类：[TradingWebApplication.java](src/main/java/com/trading/web/TradingWebApplication.java) — `@SpringBootApplication` + `@MapperScan("com.trading.web.mapper")`，无额外启动初始化逻辑。

默认端口：**8085**（`address: 0.0.0.0`，对外可访问）。

---

## 二、目录结构

```
trading-web/
├── pom.xml                         # Maven 构建文件
├── mvnw / mvnw.cmd                 # Maven Wrapper
├── logs/                            # 运行日志输出目录
└── src/main/
    ├── java/com/trading/web/
    │   ├── TradingWebApplication.java   # 启动入口
    │   ├── config/                 # 数据源配置
    │   ├── controller/             # REST 控制器
    │   ├── service/                # 业务逻辑层
    │   ├── mapper/                 # MyBatis Mapper 接口
    │   ├── entity/                 # 实体 + 枚举 + PageVO
    │   ├── dto/                    # 数据传输对象（合约排行/资金费率查询/响应）
    │   ├── security/               # AES 加解密工具
    │   └── Util/                   # 通用工具（日期转换、停机测试）
    └── resources/
        ├── application.yml          # 主配置（默认 dev）
        ├── application-prod.yml      # 生产环境（密码加密）
        ├── mapper/*.xml             # MyBatis SQL 映射（7 个）
        └── static/                  # 前端静态资源
            ├── *.html               # 页面（index/data-query/order/sar/gate-funding/core-strategy/about）
            ├── js/                  # 业务 JS + echarts + pwa + 分页
            ├── css/style.css
            ├── manifest.json / sw.js / robots.txt   # PWA 配置
            ├── audio/notification.mp3               # SSE 通知提示音
            └── images/             # logo / 二维码
```

---

## 三、技术架构分层

### 1. Web / API 层（[controller/](src/main/java/com/trading/web/controller)）

全部为 `@RestController`，返回 JSON / SSE，供前端 JS 调用：

| 控制器 | 基础路径 | 端点 | 职责 |
| --- | --- | --- | --- |
| [OrderController](src/main/java/com/trading/web/controller/OrderController.java) | `/api/order` | `GET /page`、`GET /profit/statistics` | 订单分页查询（已平仓过滤、近两周/一月窗口）、收益统计 |
| [ContractRankController](src/main/java/com/trading/web/controller/ContractRankController.java) | `/api/contract/rank` | `GET /all`、`/1h/rise`、`/4h/rise`、`/1h/volume`、`/4h/volume`、`/3month/rise` | 合约涨幅/成交量排行（1h/4h/3 月） |
| [KlineSarResultController](src/main/java/com/trading/web/controller/KlineSarResultController.java) | `/api/sar` | `GET /reverse/page` | SAR 反转信号分页 |
| [GateFundingRateController](src/main/java/com/trading/web/controller/GateFundingRateController.java) | `/api/gate/funding` | `GET /list` | Gate 资金费率列表 |
| [NewsController](src/main/java/com/trading/web/controller/NewsController.java) | `/api/news` | `GET /page`、`GET /sse/notify` | 信号新闻分页 + SSE 实时推送 |

> [NewsController](src/main/java/com/trading/web/controller/NewsController.java) 的 `/sse/notify` 使用 Servlet 异步上下文（`AsyncContext`）+ `text/event-stream` 长连接，3 秒轮询新新闻并推送，30 秒心跳，支持客户端断开检测。

### 2. 业务 / 服务层（[service/](src/main/java/com/trading/web/service)）

- [OrderService](src/main/java/com/trading/web/service/OrderService.java)：订单分页查询、已平仓过滤、时间窗口计算、分页 VO 封装、收益统计。
- [ContractRankService](src/main/java/com/trading/web/service/ContractRankService.java)：调用 Kline Mapper 获取涨幅/成交量，填充排名、空值兜底与「暂无数据」默认列表。
- [KlineSarResultService](src/main/java/com/trading/web/service/KlineSarResultService.java)：计算 3 天前时间戳分页查询 SAR 反转。
- [GateFundingRateService](src/main/java/com/trading/web/service/GateFundingRateService.java)：资金费率查询。
- [NewsService](src/main/java/com/trading/web/service/NewsService.java)：从 BookEvent 派生信号新闻、按 id 查最新、分页。

### 3. 持久层（[mapper/](src/main/java/com/trading/web/mapper) + [resources/mapper/](src/main/resources/mapper)）

- 数据库：MySQL `trading_db`（与 `trading-data-Aanalizer` 同库，本服务只读）。
- MyBatis：`mapper-locations: classpath:mapper/*.xml`，实体别名包 `com.trading.web.entity`，下划线转驼峰。
- Mapper：`ContractOrderMapper`、`KlineDataMapper`/`KlineData1dMapper`、`KlineSarResultMapper`、`GateFundingRateMapper`、`BookEventMapper`。
- 核心 SQL（[ContractOrderMapper.xml](src/main/resources/mapper/ContractOrderMapper.xml)）：以 `update_time` 与 `status=2`（已平仓）为过滤条件做分页/总数/收益统计。

### 4. 安全层（[security/](src/main/java/com/trading/web/security)）

- [CryptoUtil](src/main/java/com/trading/web/security/CryptoUtil.java)：AES 加解密，用于 prod 数据库密码解密（`encrypt.enable=1`）。
- 本服务为**对外公开只读站点**，未配置登录拦截器 / 鉴权过滤器。

### 5. 数据源与并发

- [config/DataSourceConfig](src/main/java/com/trading/web/config/DataSourceConfig.java)：手动绑定 JDBC URL、用户名、密码、HikariCP 参数，支持密码解密。
- JDK 21 虚拟线程全局开启（`spring.threads.virtual.enabled=true` + `spring.task.execution.virtual.enabled=true`）。

### 6. 前端（[static/](src/main/resources/static)）

- 页面：`index.html`（首页）、`data-query.html`（数据查询）、`order.html`（订单）、`sar.html`（SAR 信号）、`gate-funding.html`（资金费率）、`core-strategy.html`（核心策略说明）、`about.html`。
- 图表：ECharts（`js/echarts.min.js` + `js/lib/echarts.min.js`）。
- PWA：`manifest.json` + `sw.js` + `pwa.js`，可安装到桌面/离线缓存。
- 实时通知：`js/*.js` + `audio/notification.mp3`，配合 SSE 推送信号提醒。

---

## 四、业务结构 / 领域模块

本服务不含任何写入/交易逻辑，纯查询展示，面向用户呈现 `trading-data-Aanalizer` 产出的数据：

1. **订单展示模块**：合约订单分页列表、收益统计图表（ECharts）。
2. **合约排行模块**：1h/4h 涨幅与成交量排行、3 个月涨幅排行。
3. **SAR 信号模块**：抛物线 SAR 趋势反转信号分页查询。
4. **资金费率模块**：Gate.io 资金费率列表展示。
5. **信号新闻模块**：从交易信号事件（BookEvent）派生新闻流，支持 SSE 实时推送 + 浏览器音频/弹窗提醒。
6. **站点说明模块**：核心策略说明页 + 关于页。

---

## 五、构建与部署

### 环境要求
- JDK 21
- Maven 3.6+（或项目自带 `mvnw`）
- MySQL 8.x，库 `trading_db` 已由 `trading-data-Aanalizer` 初始化并持续写入数据
- 本服务端口 8085 需对终端用户开放

### 1. 配置
编辑 [src/main/resources/application.yml](src/main/resources/application.yml)（或 `application-prod.yml`）：
- `spring.datasource.url/username/password`：数据库连接（prod 用密文 + `encrypt.enable:1`，由 `CryptoUtil` 解密）。
- `server.port`：默认 8085；`server.address: 0.0.0.0` 对外开放。
- `spring.profiles.active`：默认 `dev`，部署改 `prod`。

### 2. 构建
```bash
# 在项目根目录执行
./mvnw clean package
# 产物：target/com.trading-0.0.1-SNAPSHOT.jar
```

### 3. 本地运行
```bash
# 开发（dev profile）
./mvnw spring-boot:run
# 或直接运行 jar
java -jar target/com.trading-0.0.1-SNAPSHOT.jar
# 访问：http://localhost:8085/index.html
```

### 4. 生产部署
```bash
# 指定 prod profile 启动（数据库密码自动解密）
java -jar -Dspring.profiles.active=prod target/com.trading-0.0.1-SNAPSHOT.jar
```
- 启用优雅停机：`server.shutdown=graceful`，最长等待 30s。
- 日志输出到 `logs/your-app.log`，按小时滚动，单文件 50MB，保留 7 天，上限 1GB。

### 5. 测试
```bash
./mvnw test
```

### 6. 容器化与 CI/CD

#### Dockerfile（多阶段构建）
仓库根目录提供 [Dockerfile](Dockerfile)（多阶段：`maven:3.9-eclipse-temurin-21` 构建 + `eclipse-temurin:21-jre` 运行），并附带 [.dockerignore](.dockerignore) 精简构建上下文。

```bash
# 本地构建镜像
docker build -t trading-web:latest .

# 运行容器（prod profile，连接宿主 MySQL）
docker run -d --name trading-web \
  -p 8085:8085 \
  -e SPRING_PROFILES_ACTIVE=prod \
  -e SPRING_DATASOURCE_URL='jdbc:mysql://host.docker.internal:3306/trading_db?useSSL=false&serverTimezone=Asia/Shanghai&allowPublicKeyRetrieval=true' \
  -e SPRING_DATASOURCE_USERNAME=root \
  -e SPRING_DATASOURCE_PASSWORD='<明文或密文>' \
  -e SPRING_DATASOURCE_ENCRYPT_ENABLE=1 \
  -v trading-web-logs:/app/logs \
  trading-web:latest
# 访问：http://localhost:8085/index.html
```

> 容器内默认以非 root 用户（uid 10001）运行，日志挂载到 `/app/logs`，JVM 内存按容器限制的 75% 配置并启用 ZGC。静态前端资源随 jar 一起打包，无需额外挂载。生产建议前置 Nginx 反代 8085。

#### GitLab CI（[.gitlab-ci.yml](.gitlab-ci.yml)）
两阶段流水线：
1. `build:jar`（`maven:3.9-eclipse-temurin-21`）：`mvn -B -DskipTests package`，产出 `target/*.jar` 制品（3 天过期），Maven 依赖按 `pom.xml` 缓存。
2. `build:image`（`gcr.io/kaniko-project/executor:debug`）：用 Kaniko 构建镜像并推送 GitLab Container Registry，打 `:<commit-sha>`、`:<branch>`、`:latest` 三标签，启用 Kaniko 层缓存。仅在 `main`/`master` 分支或 tag 上推送镜像，其他分支仅跑打包验证。

前置条件：仓库开启 Container Registry；Runner 支持 docker executor（Kaniko 无需 privileged runner）。`CI_REGISTRY`/`CI_REGISTRY_USER`/`CI_REGISTRY_PASSWORD` 由 GitLab 自动注入，无需额外 secret。

### 7. 与 trading-data-Aanalizer 的关系
- 两者**共用同一个 MySQL `trading_db`**：`trading-data-Aanalizer` 为数据生产与交易执行端（端口 9090，内部管理后台），`trading-web` 为只读展示端（端口 8085，对外公开）。
- 部署时需先保证 `trading-data-Aanalizer` 已建库建表并开始写入数据，`trading-web` 才有内容可展示。
- 典型部署：`trading-data-Aanalizer` 部署在内网/本机，`trading-web` 部署在公网服务器，连接同一数据库（可经 MariaDB 远程或同一主机）。

---

## 六、关键配置速查

| 配置项 | 默认值 | 说明 |
| --- | --- | --- |
| `server.port` | 8085 | 服务端口 |
| `server.address` | 0.0.0.0 | 对外监听 |
| `spring.profiles.active` | dev | 环境 |
| `spring.threads.virtual.enabled` | true | JDK21 虚拟线程 |
| `spring.datasource.url` | jdbc:mysql://localhost:3306/trading_db | 数据库（只读） |
| `mybatis.mapper-locations` | classpath:mapper/*.xml | SQL 映射 |
| `mybatis.type-aliases-package` | com.trading.web.entity | 实体别名包 |
| `spring.datasource.encrypt.enable` | 0(dev)/1(prod) | 密码解密开关 |
