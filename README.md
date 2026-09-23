# smart-trading-gate
对接gate，全量分析合约交易对，专注做空信号的触发，并自动开仓平仓的交易系统
包含两个项目，一个做数据抓取，分析，自动交易；一个作为资讯网站，分享交易数据。
# trading-data-Aanalizer 架构与部署文档

> 项目代号：`tradingdata-gate`（Maven artifactId: `tradingdata`）
> 定位：加密货币合约**数据采集 / 行情分析 / 自动交易**后端服务（数据生产端），与 `trading-web` 共享同一 MySQL 数据库 `trading_db`。

---

## 一、项目概述与技术栈

| 维度 | 选型 |
| --- | --- |
| 语言 / JDK | Java 21（启用虚拟线程） |
| 框架 | Spring Boot 3.5.7（`spring-boot-starter-parent`） |
| 构建工具 | Maven（含 `mvnw` / `mvnw.cmd` Wrapper） |
| 持久层 | MyBatis（`mybatis-spring-boot-starter` 3.0.3）+ MySQL 驱动 + MariaDB 驱动 |
| 连接池 | HikariCP（自定义 `DataSourceConfig` 手动绑定参数） |
| 模板引擎 | Thymeleaf（服务端渲染管理页面） |
| 交易 SDK | Gate.io 官方 Java SDK `io.gate:gate-api:7.2.45` |
| 金融指标 | TA-Lib 纯 Java 版 `com.tictactec:ta-lib:0.4.0`（无需本地库） |
| JSON | fastjson2 `2.0.52` |
| 邮件 | `spring-boot-starter-mail`（QQ 邮箱 SMTP） |
| 通知 | Telegram Bot（自研 `TelegramSender` / `TelegramGroupService`） |
| 工具库 | Lombok、commons-pool2、spring-boot-configuration-processor、devtools |

入口类：[TradingdataApplication.java](src/main/java/com/trading/TradingdataApplication.java) — `@SpringBootApplication` + `@EnableScheduling` + `@MapperScan("com.trading.mapper")`，并实现 `CommandLineRunner` 在启动时按 profile 执行初始化（prod 下同步 Gate 全交易对、抓 1D K 线、跑 SAR 分析）。

默认端口：**9090**（[application.yml](src/main/resources/application.yml) `server.port`）。

---

## 二、目录结构

```
trading-data-Aanalizer/
├── pom.xml                         # Maven 构建文件
├── mvnw / mvnw.cmd                 # Maven Wrapper
├── readme.md                       # 信号枚举说明（趋势/突破/止盈等）
├── todolist.md
├── sql/                             # 数据库脚本
│   ├── init.sql                    # 初始化建表
│   ├── analazer.sql                # 分析相关表
│   ├── debug.sql
│   └── trading_db_20260613.sql     # 数据库快照
├── logs/                            # 运行日志输出目录
└── src/main/
    ├── java/com/trading/
    │   ├── TradingdataApplication.java   # 启动入口
    │   ├── config/                  # 配置类（数据源、线程池、拦截器、各 Properties）
    │   ├── constant/               # RedisMQConstant 等常量
    │   ├── controller/             # Web/API 控制器
    │   ├── entity/
    │   │   ├── gate/                # Gate.io SDK 相关实体（订单/仓位/成交/账户）
    │   │   ├── mysql/               # 数据库实体 + 枚举（BookEvent/ContractOrder/KlineData 等）
    │   │   └── vo/                  # 视图对象（Result/ResultVo/统计 VO）
    │   ├── mapper/                  # MyBatis Mapper 接口
    │   ├── service/                 # 业务/分析/抓取/定时服务
    │   ├── Strategy/                # 量化策略（TrendQuantStrategy）
    │   ├── Task/                    # 定时任务封装（BookEventOrderTask / ContractOrderCloseTask）
    │   ├── AnalyzerUtils/           # 分析工具（趋势/结构/SAR/波动率计算）
    │   ├── cache/                   # 本地缓存（ExpirableMemoryCache / LocalCacheUtil）
    │   ├── security/                # 加解密 + localhost 限流拦截器
    │   └── Utils/                   # 通用工具（时间/JSON/指标/仓位计算/邮件/Telegram）
    └── resources/
        ├── application.yml          # 主配置（默认 dev）
        ├── application-dev.yml      # 开发环境
        ├── application-prod.yml      # 生产环境（密码加密）
        ├── application-test.yml     # 测试环境
        ├── mapper/*.xml             # MyBatis SQL 映射（13 个）
        ├── templates/               # Thymeleaf 页面（login/orderList/orderChart/tradeConfig）
        └── static/                  # 静态资源（css/js）
```

---

## 三、技术架构分层

### 1. Web / API 层（[controller/](src/main/java/com/trading/controller)）

| 控制器 | 类型 | 端点 | 职责 |
| --- | --- | --- | --- |
| [LoginController](src/main/java/com/trading/controller/LoginController.java) | `@Controller` | `GET /loginPage`、`POST /doLogin`、`GET /logout` | 硬编码管理员账号密码，登录成功写 `loginUser` session |
| [OrderManageController](src/main/java/com/trading/controller/OrderManageController.java) | `@Controller` | `GET /order/list`、`GET /order/cancel/{id}`、`GET /order/close/{id}`、`GET /order/chart` | 订单列表/取消/平仓/统计图表（Thymeleaf 渲染） |
| [TradeConfigController](src/main/java/com/trading/controller/TradeConfigController.java) | `@Controller` | `GET /trade/config`、`POST /trade/config`、`POST /trade/config/reset` | 交易参数配置查看/更新/重置 |
| [KlineController](src/main/java/com/trading/controller/KlineController.java) | `@RestController` | `GET /api/cex/futures`、`GET /api/gate/kline`、`GET /api/ba/kline` | K 线数据查询（CEX/Gate/Binance） |
| [PriceController](src/main/java/com/trading/controller/PriceController.java) | `@RestController` | `GET /api/price/{symbol}` | 实时价格查询（localhost 限制） |

### 2. 安全层（[security/](src/main/java/com/trading/security) + [config/](src/main/java/com/trading/config)）

- [LoginInterceptor](src/main/java/com/trading/config/LoginInterceptor.java) + [WebMvcConfig](src/main/java/com/trading/config/WebMvcConfig.java)：除 `/loginPage`、`/doLogin` 外所有路径需登录 session。
- [LocalhostInterceptor](src/main/java/com/trading/security/LocalhostInterceptor.java) + [LocalhostOnly](src/main/java/com/trading/security/LocalhostOnly.java) + [WebConfig](src/main/java/com/trading/security/WebConfig.java)：价格等敏感接口仅允许本机访问。
- [CryptoUtil](src/main/java/com/trading/security/CryptoUtil.java)：AES 加解密，用于数据库密码 / 邮箱授权码加密存储（`encrypt.enable` 开关：0=明文，1=解密）。

### 3. 业务 / 服务层（[service/](src/main/java/com/trading/service)）

服务可按职责分四类：

**① 数据采集（K 线抓取入库）**
- [KlineFetchToMysqlService](src/main/java/com/trading/service/KlineFetchToMysqlService.java)：15m K 线抓取（cron `crypto.fetch-cron`），虚拟线程并发多交易对，Gate.io futures API。
- [KlineFetch1DToDBService](src/main/java/com/trading/service/KlineFetch1DToDBService.java) / [KlineFetch1HToDBService](src/main/java/com/trading/service/KlineFetch1HToDBService.java) / [KlineFetch4HToDBService](src/main/java/com/trading/service/KlineFetch4HToDBService.java)：1D/1H/4H 周期抓取。
- [KlineFetchFromBAService](src/main/java/com/trading/service/KlineFetchFromBAService.java)：Binance futures K 线抓取。
- [CryptoSymbolFetcher](src/main/java/com/trading/service/CryptoSymbolFetcher.java) / [CryptoSymbolService](src/main/java/com/trading/service/CryptoSymbolService.java)：交易对元数据同步。
- [GateFundingRateFetchService](src/main/java/com/trading/service/GateFundingRateFetchService.java)：资金费率抓取。
- [FuturesStatsFetchService](src/main/java/com/trading/service/FuturesStatsFetchService.java)：合约统计抓取。

**② 行情分析（多周期多策略）**
- [KlineAnalyzer](src/main/java/com/trading/service/KlineAnalyzer.java)：15m 主分析（JUMPUPSHORT 事件生成，含横盘/阈值判断）。
- [KlineShortTermAnalyzer](src/main/java/com/trading/service/KlineShortTermAnalyzer.java) / [KlineMidTermAnalyzer](src/main/java/com/trading/service/KlineMidTermAnalyzer.java) / [KlineLongTermAnalyzer](src/main/java/com/trading/service/KlineLongTermAnalyzer.java)：短/中/长周期分析。
- [KlineUltraResonanceAnalyzer](src/main/java/com/trading/service/KlineUltraResonanceAnalyzer.java)：超周期共振分析。
- [Kline1HAnalyzer](src/main/java/com/trading/service/Kline1HAnalyzer.java)：1H 周期分析。
- [KlineSARAnalyzer](src/main/java/com/trading/service/KlineSARAnalyzer.java)：SAR 抛物线反转分析（每天 10 点）。
- [StructureTrendAnalyzer](src/main/java/com/trading/service/StructureTrendAnalyzer.java)：主力/散户结构趋势分析。
- [OiPriceDivergenceAnalyzer](src/main/java/com/trading/service/OiPriceDivergenceAnalyzer.java)：持仓量与价格背离分析。
- 分析算法工具集中在 [AnalyzerUtils/](src/main/java/com/trading/AnalyzerUtils)（TrendCalculator / SarCalculator / StructureIndexAnalyzer 等）。

**③ 事件与订单（自动交易）**
- [BookEventService](src/main/java/com/trading/service/BookEventService.java) / [BookEventPreService](src/main/java/com/trading/service/BookEventPreService.java)：信号事件（BookEvent）处理 → 真实/模拟下单。
- [ContractOrderService](src/main/java/com/trading/service/ContractOrderService.java) / [RealContractOrderService](src/main/java/com/trading/service/RealContractOrderService.java)：合约订单开/平仓（多空盈亏按最新 1m K 线计算）。
- [GateContractService](src/main/java/com/trading/service/GateContractService.java)：Gate.io 合约下单封装。
- [FuturesOrderService](src/main/java/com/trading/service/FuturesOrderService.java) / [TradeProfitService](src/main/java/com/trading/service/TradeProfitService.java)：订单与收益查询。
- [TradeParamConfigService](src/main/java/com/trading/service/TradeParamConfigService.java)：交易参数配置管理。

**④ 定时任务封装（[Task/](src/main/java/com/trading/Task)）**
- [BookEventOrderTask](src/main/java/com/trading/Task/BookEventOrderTask.java)：`@Scheduled(cron = "0 * * * * *")` 每分钟执行下单事件。
- [ContractOrderCloseTask](src/main/java/com/trading/Task/ContractOrderCloseTask.java)：`@Scheduled(cron = "55 */5 * * * *")` 每 5 分钟检查平仓。

> 注：部分 `@Scheduled` 在源码中被注释，实际生效的调度由 `@EnableScheduling` + 上述 Task/Service 共同驱动，cron 表达式集中于 `application.yml` 的 `crypto.*` 配置项。

### 4. 持久层（[mapper/](src/main/java/com/trading/mapper) + [resources/mapper/](src/main/resources/mapper)）

- 数据库：MySQL `trading_db`（[application.yml](src/main/resources/application.yml) `spring.datasource.url`）。
- MyBatis：`mapper-locations: classpath:mapper/*.xml`，实体别名包 `com.trading.entity.mysql`，下划线转驼峰。
- 核心 Mapper：`KlineDatalMapper`/`KlineData1hMapper`/`KlineData4hMapper`/`KlineData1dMapper`（多周期 K 线）、`BookEventMapper`/`BookEventPreMapper`（事件）、`ContractOrderMapper`/`RealContractOrderMapper`（订单）、`GateFundingRateMapper`、`KlineSarResultMapper`、`CryptoSymbolMapper`、`FuturesOrderMapper`、`FuturesStatsMapper`、`TradeProfitMapper`。

### 5. 缓存与并发

- [cache/ExpirableMemoryCache](src/main/java/com/trading/cache/ExpirableMemoryCache.java) + [LocalCacheUtil](src/main/java/com/trading/cache/LocalCacheUtil.java)：本地可过期缓存，用于分析任务 15 分钟去重避免重复触发。
- [config/ExecutorConfig](src/main/java/com/trading/config/ExecutorConfig.java)：线程池配置；JDK 21 虚拟线程全局开启（`spring.threads.virtual.enabled=true`）。

### 6. 通知

- [Utils/EmailService](src/main/java/com/trading/Utils/EmailService.java)：QQ 邮箱告警。
- [Utils/TelegramSender](src/main/java/com/trading/Utils/TelegramSender.java) / [TelegramGroupService](src/main/java/com/trading/Utils/TelegramGroupService.java) / [TelegramService](src/main/java/com/trading/Utils/TelegramService.java)：多群信号推送（信号群/告警群/巨鲸群/测试群，见 `telegram.groups` 配置）。

---

## 四、业务结构 / 领域模块

整体是一条**采集 → 分析 → 决策 → 执行 → 复盘**的量化自动交易流水线：

1. **行情采集模块**：从 Gate.io / Binance 拉取多周期 K 线、资金费率、合约统计、交易对清单，落库 `trading_db`。
2. **多策略分析模块**：短(15m)/中(4h)/长(1d) 三周期 + SAR 反转 + 结构趋势 + 持仓量背离 + 超周期共振，生成 `JUMPUPSHORT` 等信号事件（详见 [readme.md](readme.md) 信号枚举）。
3. **事件 & 自动交易模块**：信号进入 BookEvent 队列，定时任务处理下单（支持真实 Gate 合约下单与模拟下单），订单按止盈止损/最新价定时平仓。
4. **交易参数配置模块**：可用资金、单笔仓位、最大持仓数、杠杆、止盈止损比例等可在线调整（`/trade/config`）。
5. **管理后台模块**：Thymeleaf 页面提供登录、订单列表/图表、交易参数配置。
6. **通知告警模块**：信号与告警通过 Telegram 群 + 邮件外发。

---

## 五、构建与部署

### 环境要求
- JDK 21
- Maven 3.6+（或直接用项目自带 `mvnw`）
- MySQL 8.x（数据库 `trading_db`）
- 网络可访问 Gate.io（`api.gateio.ws`）/ Binance（`fapi.binance.com`）/ QQ SMTP / Telegram API

### 1. 初始化数据库
```bash
# 在 MySQL 中创建库并导入结构
mysql -uroot -p -e "CREATE DATABASE trading_db DEFAULT CHARSET utf8mb4;"
mysql -uroot -p trading_db < sql/init.sql
# 按需导入 sql/analazer.sql 与快照
```

### 2. 配置
编辑 [src/main/resources/application.yml](src/main/resources/application.yml)（或对应 profile 文件）：
- `spring.datasource.url/username/password`：数据库连接（prod 用密文 + `encrypt.enable:1`）。
- `crypto.*`：抓取/分析 cron 与阈值。
- `trade.config.*`：交易参数默认值。
- `gate.api-key/api-secret`：Gate.io API 凭证。
- `spring.mail.*` / `telegram.*` / `email.*`：通知渠道。
- `spring.profiles.active`：默认 `dev`，部署改 `prod`。

### 3. 构建
```bash
# 在项目根目录执行（跳过测试，pom 已设 maven.test.skip=true）
./mvnw clean package
# 产物：target/tradingdata-0.0.1-SNAPSHOT.jar
```

### 4. 本地运行
```bash
# 开发（dev profile，默认即 dev）
./mvnw spring-boot:run
# 或直接运行 jar
java -jar target/tradingdata-0.0.1-SNAPSHOT.jar
# 访问管理后台：http://localhost:9090/loginPage
```

### 5. 生产部署
```bash
# 指定 prod profile 启动（密码自动解密，启动时同步 Gate 全交易对并抓 1D K 线）
java -jar -Dspring.profiles.active=prod target/tradingdata-0.0.1-SNAPSHOT.jar
```
- 启用优雅停机：`server.shutdown=graceful`，最长等待 30s。
- 日志输出到 `logs/your-app.log`，按小时滚动，单文件 50MB，保留 7 天，上限 1GB。

### 6. 测试
```bash
./mvnw test        # pom 默认跳过测试编译，如需执行需移除 maven.test.skip
```

### 7. 容器化与 CI/CD

#### Dockerfile（多阶段构建）
仓库根目录提供 [Dockerfile](Dockerfile)（多阶段：`maven:3.9-eclipse-temurin-21` 构建 + `eclipse-temurin:21-jre` 运行），并附带 [.dockerignore](.dockerignore) 精简构建上下文。

```bash
# 本地构建镜像
docker build -t tradingdata-gate:latest .

# 运行容器（prod profile，连接宿主 MySQL）
docker run -d --name tradingdata \
  -p 9090:9090 \
  -e SPRING_PROFILES_ACTIVE=prod \
  -e SPRING_DATASOURCE_URL='jdbc:mysql://host.docker.internal:3306/trading_db?useSSL=false&serverTimezone=Asia/Shanghai&allowPublicKeyRetrieval=true' \
  -e SPRING_DATASOURCE_USERNAME=root \
  -e SPRING_DATASOURCE_PASSWORD='<明文或密文>' \
  -e SPRING_DATASOURCE_ENCRYPT_ENABLE=1 \
  -v tradingdata-logs:/app/logs \
  tradingdata-gate:latest
# 管理后台：http://localhost:9090/loginPage
```

> 容器内默认以非 root 用户（uid 10001）运行，日志挂载到 `/app/logs`，JVM 内存按容器限制的 75% 配置并启用 ZGC。`SPRING_PROFILES_ACTIVE` 等配置均通过环境变量覆盖 `application.yml`。

#### GitLab CI（[.gitlab-ci.yml](.gitlab-ci.yml)）
两阶段流水线：
1. `build:jar`（`maven:3.9-eclipse-temurin-21`）：`mvn -B -DskipTests package`，产出 `target/*.jar` 制品（3 天过期），Maven 依赖按 `pom.xml` 缓存。
2. `build:image`（`gcr.io/kaniko-project/executor:debug`）：用 Kaniko 构建镜像并推送 GitLab Container Registry，打 `:<commit-sha>`、`:<branch>`、`:latest` 三标签，启用 Kaniko 层缓存。仅在 `main`/`master` 分支或 tag 上推送镜像，其他分支仅跑打包验证。

前置条件：仓库开启 Container Registry；Runner 支持 docker executor（Kaniko 无需 privileged runner）。`CI_REGISTRY`/`CI_REGISTRY_USER`/`CI_REGISTRY_PASSWORD` 由 GitLab 自动注入，无需额外 secret。

---

## 六、关键配置速查

| 配置项 | 默认值 | 说明 |
| --- | --- | --- |
| `server.port` | 9090 | 服务端口 |
| `spring.profiles.active` | dev | 环境 |
| `spring.threads.virtual.enabled` | true | JDK21 虚拟线程 |
| `spring.datasource.url` | jdbc:mysql://localhost:3306/trading_db | 数据库 |
| `mybatis.mapper-locations` | classpath:mapper/*.xml | SQL 映射 |
| `crypto.fetch-cron` | `0 */1 * * * *` | 15m K 线抓取 |
| `crypto.analyzer-cron` | `0 */1 * * * *` | 15m 分析 |
| `crypto.analyzer-cron-sar` | `0 0 10 * * ?` | SAR 每日 10 点 |
| `crypto.bookevent-cron` | `0 */1 * * * *` | 下单事件处理 |
| `crypto.closeorder-cron` | `0 */1 * * * *` | 平仓 |
| `trade.config.auto-trade` | false | 自动交易开关 |
| `gate.api-key/secret` | （配置文件内） | Gate.io 凭证 |
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
