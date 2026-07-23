variable "tenancy_ocid" {
  description = "OCI Tenancy OCID."
  type        = string
  default     = ""
}

variable "user_ocid" {
  description = "OCI User OCID."
  type        = string
  default     = ""
}

variable "fingerprint" {
  description = "OCI API Key Fingerprint."
  type        = string
  default     = ""
}

variable "private_key_path" {
  description = "Path to OCI API Private Key."
  type        = string
  default     = ""
}

variable "private_key_password" {
  description = "Passphrase for encrypted OCI API Private Key."
  type        = string
  sensitive   = true
  default     = ""
}

variable "region" {
  description = "OCI Region for OKE, VCN, and PostgreSQL compute (e.g. ap-kulai-2)."
  type        = string
  default     = "ap-kulai-2"
}

variable "compartment_id" {
  description = "OCI Compartment OCID for benchmark resources."
  type        = string
}

variable "project" {
  description = "Project name prefix for OCI benchmark resources."
  type        = string
  default     = "skripsi"
}

variable "execution_mode" {
  description = "Benchmark execution mode: sequential (1 OKE cluster) or parallel (2 OKE clusters)."
  type        = string
  default     = "sequential"

  validation {
    condition     = contains(["sequential", "parallel"], var.execution_mode)
    error_message = "execution_mode must be sequential or parallel."
  }
}

variable "node_shape" {
  description = "OCI Compute shape for OKE worker nodes."
  type        = string
  default     = "VM.Standard.E4.Flex"
}

variable "app_node_ocpus" {
  description = "OCPU count for app node pool (1 OCPU = 2 vCPUs on x86_64)."
  type        = number
  default     = 8
}

variable "app_node_memory_in_gbs" {
  description = "Memory in GB for app node pool."
  type        = number
  default     = 32
}

variable "app_node_count" {
  description = "Node count for app node pool."
  type        = number
  default     = 1
}

variable "testing_node_ocpus" {
  description = "OCPU count for testing node pool."
  type        = number
  default     = 1
}

variable "testing_node_memory_in_gbs" {
  description = "Memory in GB for testing node pool."
  type        = number
  default     = 4
}

variable "testing_node_count" {
  description = "Node count for testing node pool."
  type        = number
  default     = 1
}

variable "node_image_id" {
  description = "OCID of OKE Oracle Linux Worker Image for the target region."
  type        = string
  default     = ""
}

variable "kubernetes_version" {
  description = "OKE Kubernetes version."
  type        = string
  default     = "v1.36.0"
}

variable "db_password" {
  description = "Password for PostgreSQL database system."
  type        = string
  sensitive   = true
}

variable "db_ocpus" {
  description = "OCPU count for PostgreSQL DB instance."
  type        = number
  default     = 2
}

variable "db_memory_in_gbs" {
  description = "Memory in GB for PostgreSQL DB instance."
  type        = number
  default     = 16
}

variable "db_shape" {
  description = "OCI Compute shape for PostgreSQL DB system."
  type        = string
  default     = "VM.Standard.E5.Flex"
}

variable "testing_node_shape" {
  description = "OCI Compute shape for OKE testing worker nodes."
  type        = string
  default     = "VM.Standard3.Flex"
}

variable "db_version" {
  description = "PostgreSQL major version."
  type        = string
  default     = "17"
}
