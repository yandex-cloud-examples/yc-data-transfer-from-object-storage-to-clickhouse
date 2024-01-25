# Infrastructure for the Yandex Cloud Object Storage, Managed Service for ClickHouse® and Data Transfer
#
# RU: https://cloud.yandex.ru/docs/data-transfer/tutorials/object-storage-to-clickhouse
# EN: https://cloud.yandex.com/en/docs/data-transfer/tutorials/object-storage-to-clickhouse
#
# Specify the following settings:
locals {

  folder_id   = "b1gmm82dtdb31itflrvj" # Set your cloud folder ID, same as for provider.
  bucket_name = "os-to-ch"             # Set a unique bucket name.
  ch_password = ""                     # Set a password for the ClickHouse® admin user.

  # Specify these settings ONLY AFTER the cluster is created. Then run the "terraform apply" command again.
  # You should set up a source endpoint for the Object Storage bucket using the GUI to obtain endpoint's ID.
  source_endpoint_id = "" # Set the source endpoint ID.
  transfer_enabled   = 0  # Set to 1 to enable the transfer.

  # The following settings are predefined. Change them only if necessary.
  network_name          = "mch-network"        # Name of the network
  subnet_a_name         = "mch-subnet-a"       # Name of the subnet
  subnet_b_name         = "mch-subnet-b"       # Name of the subnet
  subnet_d_name         = "mch-subnet-d"       # Name of the subnet
  zone_a_v4_cidr_blocks = "10.1.0.0/16"        # CIDR block for the subnet
  zone_b_v4_cidr_blocks = "10.2.0.0/16"        # CIDR block for the subnet
  zone_d_v4_cidr_blocks = "10.3.0.0/16"        # CIDR block for the subnet
  sa-name               = "storage-editor"     # Name of the service account
  security_group_name   = "mch-security-group" # Name of the security group
  mch_cluster_name      = "mch-cluster"        # Name of the ClickHouse® cluster
  ch_db_name            = "db1"                # Name of the ClickHouse® database
  ch_username           = "user1"              # Name of the ClickHouse® admin user
  target_endpoint_name  = "mch-target"         # Name of the target endpoint for the ClickHouse® cluster
  transfer_name         = "s3-mch-transfer"    # Name of the transfer from the Object Storage bucket to the Managed Service for ClickHouse® cluster
}

# Network infrastructure for the Managed Service for ClickHouse® cluster

resource "yandex_vpc_network" "network" {
  description = "Network for the Managed Service for ClickHouse® cluster"
  name        = local.network_name
}

resource "yandex_vpc_subnet" "subnet-a" {
  description    = "Subnet in the ru-central1-a availability zone"
  name           = local.subnet_a_name
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = [local.zone_a_v4_cidr_blocks]
}

resource "yandex_vpc_subnet" "subnet-b" {
  description    = "Subnet in the ru-central1-b availability zone"
  name           = local.subnet_b_name
  zone           = "ru-central1-b"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = [local.zone_b_v4_cidr_blocks]
}

resource "yandex_vpc_subnet" "subnet-d" {
  description    = "Subnet in the ru-central1-d availability zone"
  name           = local.subnet_d_name
  zone           = "ru-central1-d"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = [local.zone_d_v4_cidr_blocks]
}

resource "yandex_vpc_security_group" "security_group" {
  description = "Security group for the Managed Service for ClickHouse® cluster"
  name        = local.security_group_name
  network_id  = yandex_vpc_network.network.id

  ingress {
    description    = "Allows connections to the Managed Service for ClickHouse® cluster from the internet"
    protocol       = "TCP"
    port           = 9440
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description    = "Allows all outgoing traffic"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }
}

# Infrastructure for the Object Storage bucket

# Create a service account.
resource "yandex_iam_service_account" "example-sa" {
  folder_id = local.folder_id
  name      = local.sa-name
}

# Create a static key for the service account.
resource "yandex_iam_service_account_static_access_key" "sa-static-key" {
  service_account_id = yandex_iam_service_account.example-sa.id
}

# Grant a role to the service account. The role allows to perform any operations with buckets and objects.
resource "yandex_resourcemanager_folder_iam_binding" "s3-admin" {
  folder_id = local.folder_id
  role      = "storage.editor"

  members = [
    "serviceAccount:${yandex_iam_service_account.example-sa.id}",
  ]
}

# Create a Lockbox secret.
resource "yandex_lockbox_secret" "sa_key_secret" {
  name        = "sa_key_secret"
  description = "Contains a static key pair to create an endpoint"
  folder_id   = local.folder_id
}

# Create a version of Lockbox secret with the static key pair.
resource "yandex_lockbox_secret_version" "first_version" {
  secret_id = yandex_lockbox_secret.sa_key_secret.id
  entries {
    key        = "access_key"
    text_value = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  }
  entries {
    key        = "secret_key"
    text_value = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
  }
}

# Create the Yandex Object Storage bucket.
resource "yandex_storage_bucket" "example-bucket" {
  bucket     = local.bucket_name
  access_key = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
}

# Infrastructure for the Managed Service for ClickHouse® cluster

resource "yandex_mdb_clickhouse_cluster" "mch-cluster" {
  description        = "Managed Service for ClickHouse® cluster"
  name               = local.mch_cluster_name
  environment        = "PRODUCTION"
  network_id         = yandex_vpc_network.network.id
  security_group_ids = [yandex_vpc_security_group.security_group.id]

  clickhouse {
    resources {
      resource_preset_id = "s2.micro" # 2 vCPU, 8 GB RAM
      disk_type_id       = "network-ssd"
      disk_size          = 10 # GB
    }
  }

  zookeeper {
    resources {
      resource_preset_id = "s2.micro" # 2 vCPU, 8 GB RAM
      disk_type_id       = "network-ssd"
      disk_size          = 10 # GB
    }
  }

  host {
    type             = "CLICKHOUSE"
    zone             = "ru-central1-a"
    subnet_id        = yandex_vpc_subnet.subnet-a.id
    assign_public_ip = true # Required for connection from the internet
  }

  host {
    type             = "CLICKHOUSE"
    zone             = "ru-central1-b"
    subnet_id        = yandex_vpc_subnet.subnet-b.id
    assign_public_ip = true # Required for connection from the internet
  }

  host {
    type      = "ZOOKEEPER"
    zone      = "ru-central1-a"
    subnet_id = yandex_vpc_subnet.subnet-a.id
  }

  host {
    type      = "ZOOKEEPER"
    zone      = "ru-central1-b"
    subnet_id = yandex_vpc_subnet.subnet-b.id
  }

  host {
    type      = "ZOOKEEPER"
    zone      = "ru-central1-d"
    subnet_id = yandex_vpc_subnet.subnet-d.id
  }

  database {
    name = local.ch_db_name
  }

  user {
    name     = local.ch_username
    password = local.ch_password
    permission {
      database_name = local.ch_db_name
    }
  }
}

# Data Transfer infrastructure

resource "yandex_datatransfer_endpoint" "mch_target" {
  description = "Target endpoint for ClickHouse® cluster"
  name        = local.target_endpoint_name
  settings {
    clickhouse_target {
      connection {
        connection_options {
          mdb_cluster_id = yandex_mdb_clickhouse_cluster.mch-cluster.id
          database       = local.ch_db_name
          user           = local.ch_username
          password {
            raw = local.ch_password
          }
        }
      }
    }
  }
}

resource "yandex_datatransfer_transfer" "objstorage-mch-transfer" {
  count       = local.transfer_enabled
  description = "Transfer from the Object Storage bucket to the Managed Service for ClickHouse® cluster"
  name        = local.transfer_name
  source_id   = local.source_endpoint_id
  target_id   = yandex_datatransfer_endpoint.mch_target.id
  type        = "SNAPSHOT_AND_INCREMENT" # Copy all data from the source cluster and start replication
}
