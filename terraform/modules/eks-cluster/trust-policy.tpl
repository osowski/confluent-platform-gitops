{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Principal": {
      "Federated": "${oidc_provider_arn}"
    },
    "Condition": {
      "StringEquals": {
        "${oidc_provider}:sub": "system:serviceaccount:${namespace}:${sa_name}",
        "${oidc_provider}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
