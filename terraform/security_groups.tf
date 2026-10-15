###############################################################################
# Bastion — the only host reachable from the internet
###############################################################################

resource "aws_security_group" "bastion" {
  name        = "${var.name_prefix}-bastion"
  description = "Bastion: SSH from admin CIDRs only."
  vpc_id      = aws_vpc.main.id

  dynamic "ingress" {
    for_each = length(var.allowed_admin_cidrs) > 0 ? [1] : []
    content {
      description = "SSH from admin"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.allowed_admin_cidrs
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-bastion-sg" }
}

###############################################################################
# SIFT — gateway, portal, XRDP, SMB server
###############################################################################

resource "aws_security_group" "sift" {
  name        = "${var.name_prefix}-sift"
  description = "SIFT workstation."
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  ingress {
    description     = "XRDP from bastion (tunneled)"
    from_port       = 3389
    to_port         = 3389
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  ingress {
    description     = "sift-gateway / Examiner Portal from bastion (tunneled)"
    from_port       = 4508
    to_port         = 4508
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-sift-sg" }
}

# SMB from the Windows worker to the SIFT case dir. Separate rule to avoid a
# cycle between the sift and windows SGs.
resource "aws_security_group_rule" "sift_smb_from_windows" {
  count                    = var.enable_windows ? 1 : 0
  type                     = "ingress"
  description              = "SMB (case dir) from Windows worker"
  from_port                = 445
  to_port                  = 445
  protocol                 = "tcp"
  security_group_id        = aws_security_group.sift.id
  source_security_group_id = aws_security_group.windows[0].id
}

###############################################################################
# OpenSearch data store
###############################################################################

resource "aws_security_group" "opensearch" {
  count       = var.enable_opensearch ? 1 : 0
  name        = "${var.name_prefix}-opensearch"
  description = "OpenSearch data store."
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "OpenSearch API from SIFT"
    from_port       = 9200
    to_port         = 9200
    protocol        = "tcp"
    security_groups = [aws_security_group.sift.id]
  }

  ingress {
    description     = "SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-opensearch-sg" }
}

###############################################################################
# Windows — wintools-mcp
###############################################################################

resource "aws_security_group" "windows" {
  count       = var.enable_windows ? 1 : 0
  name        = "${var.name_prefix}-windows"
  description = "Windows wintools-mcp host."
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "wintools-mcp from SIFT gateway"
    from_port       = 4624
    to_port         = 4624
    protocol        = "tcp"
    security_groups = [aws_security_group.sift.id]
  }

  ingress {
    description     = "RDP admin from bastion (tunneled)"
    from_port       = 3389
    to_port         = 3389
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-windows-sg" }
}

###############################################################################
# REMnux — remnux-mcp
###############################################################################

resource "aws_security_group" "remnux" {
  count       = var.enable_remnux ? 1 : 0
  name        = "${var.name_prefix}-remnux"
  description = "REMnux malware-analysis host."
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "remnux-mcp from SIFT (LLM client)"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.sift.id]
  }

  ingress {
    description     = "SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-remnux-sg" }
}
