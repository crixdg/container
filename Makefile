

COMPOSE := docker compose

# -- Database --

compose-postgres:
	$(COMPOSE) -f docker-composes/database/postgres/postgres.yaml up -d

compose-postgres-down:
	$(COMPOSE) -f docker-composes/database/postgres/postgres.yaml down -v

compose-redis:
	$(COMPOSE) -f docker-composes/database/redis/redis.yml up -d

compose-redis-down:
	$(COMPOSE) -f docker-composes/database/redis/redis.yml down -v

compose-cassandra:
	$(COMPOSE) -f docker-composes/database/cassandra/cassandra.yaml up -d

compose-cassandra-down:
	$(COMPOSE) -f docker-composes/database/cassandra/cassandra.yaml down -v

compose-mongodb:
	$(COMPOSE) -f docker-composes/database/mongodb/mongodb.yaml up -d

compose-mongodb-down:
	$(COMPOSE) -f docker-composes/database/mongodb/mongodb.yaml down -v

compose-mysql:
	$(COMPOSE) -f docker-composes/database/mysql/mysql.yaml up -d

compose-mysql-down:
	$(COMPOSE) -f docker-composes/database/mysql/mysql.yaml down -v

compose-sql-server:
	$(COMPOSE) -f docker-composes/database/sql-server/sql-server.yaml up -d

compose-sql-server-down:
	$(COMPOSE) -f docker-composes/database/sql-server/sql-server.yaml down -v

compose-keydb:
	$(COMPOSE) -f docker-composes/database/keydb/keydb.yaml up -d

compose-keydb-down:
	$(COMPOSE) -f docker-composes/database/keydb/keydb.yaml down -v

# -- Streaming --

compose-kafka:
	$(COMPOSE) -f docker-composes/kafka/kafka.yaml up -d

compose-kafka-down:
	$(COMPOSE) -f docker-composes/kafka/kafka.yaml down -v

compose-confluent:
	$(COMPOSE) -f docker-composes/kafka/confluent.yaml up -d

compose-confluent-down:
	$(COMPOSE) -f docker-composes/kafka/confluent.yaml down -v

# -- IAM --

compose-keycloak:
	$(COMPOSE) -f docker-composes/keycloak/keycloak.yaml up -d

compose-keycloak-down:
	$(COMPOSE) -f docker-composes/keycloak/keycloak.yaml down -v

compose-zitadel:
	$(COMPOSE) -f docker-composes/zitadel/zitadel.yaml up -d

compose-zitadel-down:
	$(COMPOSE) -f docker-composes/zitadel/zitadel.yaml down -v

compose-ory-hydra:
	$(COMPOSE) -f docker-composes/ory/ory-hydra/ory_hydra.yaml up -d

compose-ory-hydra-down:
	$(COMPOSE) -f docker-composes/ory/ory-hydra/ory_hydra.yaml down -v

compose-ory-kratos:
	$(COMPOSE) -f docker-composes/ory/ory-kratos/ory_kratos.yaml up -d

compose-ory-kratos-down:
	$(COMPOSE) -f docker-composes/ory/ory-kratos/ory_kratos.yaml down -v

# -- Observability --

compose-elk:
	$(COMPOSE) -f docker-composes/observability/elk/elk.yaml up -d

compose-elk-down:
	$(COMPOSE) -f docker-composes/observability/elk/elk.yaml down -v

compose-prometheus:
	$(COMPOSE) -f docker-composes/observability/prometheus/prometheus.yaml up -d

compose-prometheus-down:
	$(COMPOSE) -f docker-composes/observability/prometheus/prometheus.yaml down -v

compose-grafana:
	$(COMPOSE) -f docker-composes/observability/grafana/grafana.yaml up -d

compose-grafana-down:
	$(COMPOSE) -f docker-composes/observability/grafana/grafana.yaml down -v

compose-victoria-metrics:
	$(COMPOSE) -f docker-composes/observability/victoria-metrics/victoria_metrics.yaml up -d

compose-victoria-metrics-down:
	$(COMPOSE) -f docker-composes/observability/victoria-metrics/victoria_metrics.yaml down -v

compose-jaeger-collector:
	$(COMPOSE) -f docker-composes/observability/jaeger/jaeger_collector.yaml up -d

compose-jaeger-ingester:
	$(COMPOSE) -f docker-composes/observability/jaeger/jaeger_ingester.yaml up -d

compose-jaeger-query:
	$(COMPOSE) -f docker-composes/observability/jaeger/jaeger_query.yaml up -d

compose-jaeger-down:
	$(COMPOSE) -f docker-composes/observability/jaeger/jaeger_collector.yaml \
		-f docker-composes/observability/jaeger/jaeger_ingester.yaml \
		-f docker-composes/observability/jaeger/jaeger_query.yaml down -v

compose-cadvisor:
	$(COMPOSE) -f docker-composes/observability/cadvisor/cadvisor.yaml up -d

compose-cadvisor-down:
	$(COMPOSE) -f docker-composes/observability/cadvisor/cadvisor.yaml down -v

compose-node-exporter:
	$(COMPOSE) -f docker-composes/observability/node-exporter/node_exporter.yaml up -d

compose-node-exporter-down:
	$(COMPOSE) -f docker-composes/observability/node-exporter/node_exporter.yaml down -v

compose-otel:
	$(COMPOSE) -f docker-composes/observability/otel/otel_collector_host.yaml up -d

compose-otel-down:
	$(COMPOSE) -f docker-composes/observability/otel/otel_collector_host.yaml down -v

compose-process-exporter:
	$(COMPOSE) -f docker-composes/observability/process-exporter/process_exporter.yaml up -d

compose-process-exporter-down:
	$(COMPOSE) -f docker-composes/observability/process-exporter/process_exporter.yaml down -v

# -- Dev Tools --

compose-nexus:
	$(COMPOSE) -f docker-composes/devtools/nexus/nexus.yaml up -d

compose-nexus-down:
	$(COMPOSE) -f docker-composes/devtools/nexus/nexus.yaml down -v

compose-sonarqube:
	$(COMPOSE) -f docker-composes/devtools/sonarqube/sonarqube.yaml up -d

compose-sonarqube-down:
	$(COMPOSE) -f docker-composes/devtools/sonarqube/sonarqube.yaml down -v

compose-nifi:
	$(COMPOSE) -f docker-composes/devtools/nifi/nifi.yaml up -d

compose-nifi-down:
	$(COMPOSE) -f docker-composes/devtools/nifi/nifi.yaml down -v

# -- Cleanup --

compose-clean-all:
	docker system prune -a -f --volumes

compose-clean-images:
	docker image prune -a -f

compose-clean-containers:
	docker container prune -f

compose-clean-volumes:
	docker volume prune -f

compose-clean-networks:
	docker network prune -f
