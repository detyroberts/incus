s3cmdrun () {
  # shellcheck disable=2039,3043
  local backend accessKey secreyKey
  backend="${1}"
  accessKey="${2}"
  secreyKey="${3}"
  shift 3

  if [ "$backend" = "ceph" ]; then
    timeout -k 5 5 s3cmd \
      --access_key="${accessKey}" \
      --secret_key="${secreyKey}" \
      --host="${s3Endpoint}" \
      --host-bucket="${s3Endpoint}" \
      --no-ssl \
      "$@"
  else
    timeout -k 5 5 s3cmd \
      --access_key="${accessKey}" \
      --secret_key="${secreyKey}" \
      --host="${s3Endpoint}" \
      --host-bucket="${s3Endpoint}" \
      --ssl \
      --no-check-certificate \
      "$@"
  fi
}

test_storage_buckets() {
  # shellcheck disable=2039,3043
  local incus_backend

  incus_backend=$(storage_backend "$INCUS_DIR")

  if [ "$incus_backend" = "ceph" ]; then
    if [ -z "${INCUS_CEPH_CEPHOBJECT_RADOSGW:-}" ]; then
      # Check INCUS_CEPH_CEPHOBJECT_RADOSGW specified for ceph bucket tests.
      export TEST_UNMET_REQUIREMENT="INCUS_CEPH_CEPHOBJECT_RADOSGW not specified"
      return
    fi
  elif ! command -v minio ; then
    # Check minio is installed for local storage pool buckets.
    export TEST_UNMET_REQUIREMENT="minio command not found"
    return
  fi

  poolName=$(inc profile device get default root pool)
  bucketPrefix="inc$$"

  # Check cephobject.radosgw.endpoint is required for cephobject pools.
  if [ "$incus_backend" = "ceph" ]; then
    ! inc storage create s3 cephobject || false
    inc storage create s3 cephobject cephobject.radosgw.endpoint="${INCUS_CEPH_CEPHOBJECT_RADOSGW}"
    inc storage show s3
    poolName="s3"
    s3Endpoint="${INCUS_CEPH_CEPHOBJECT_RADOSGW}"
  else
    # Create a loop device for dir pools as MinIO doesn't support running on tmpfs (which the test suite can do).
    if [ "$incus_backend" = "dir" ]; then
      configure_loop_device loop_file_1 loop_device_1
      # shellcheck disable=SC2154
      mkfs.ext4 "${loop_device_1}"
      mkdir "${TEST_DIR}/${bucketPrefix}"
      mount "${loop_device_1}" "${TEST_DIR}/${bucketPrefix}"
      losetup -d "${loop_device_1}"
      mkdir "${TEST_DIR}/${bucketPrefix}/s3"
      inc storage create s3 dir source="${TEST_DIR}/${bucketPrefix}/s3"
      poolName="s3"
    fi

    buckets_addr="127.0.0.1:$(local_tcp_port)"
    inc config set core.storage_buckets_address "${buckets_addr}"
    s3Endpoint="https://${buckets_addr}"
  fi

  # Check bucket name validation.
  ! inc storage bucket create "${poolName}" .foo || false
  ! inc storage bucket create "${poolName}" fo || false
  ! inc storage bucket create "${poolName}" fooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooo || false
  ! inc storage bucket create "${poolName}" "foo bar" || false

  # Create bucket.
  initCreds=$(inc storage bucket create "${poolName}" "${bucketPrefix}.foo" user.foo=comment)
  initAccessKey=$(echo "${initCreds}" | awk '{ if ($2 == "access" && $3 == "key:") {print $4}}')
  initSecretKey=$(echo "${initCreds}" | awk '{ if ($2 == "secret" && $3 == "key:") {print $4}}')
  s3cmdrun "${incus_backend}" "${initAccessKey}" "${initSecretKey}" ls | grep -F "${bucketPrefix}.foo"

  inc storage bucket list "${poolName}" | grep -F "${bucketPrefix}.foo"
  inc storage bucket show "${poolName}" "${bucketPrefix}.foo"

  # Create bucket keys.

  # Create admin key with randomly generated credentials.
  creds=$(inc storage bucket key create "${poolName}" "${bucketPrefix}.foo" admin-key --role=admin)
  adAccessKey=$(echo "${creds}" | awk '{ if ($1 == "Access" && $2 == "key:") {print $3}}')
  adSecretKey=$(echo "${creds}" | awk '{ if ($1 == "Secret" && $2 == "key:") {print $3}}')

  # Create read-only key with manually specified credentials.
  creds=$(inc storage bucket key create "${poolName}" "${bucketPrefix}.foo" ro-key --role=read-only --access-key="${bucketPrefix}.foo.ro" --secret-key="password")
  roAccessKey=$(echo "${creds}" | awk '{ if ($1 == "Access" && $2 == "key:") {print $3}}')
  roSecretKey=$(echo "${creds}" | awk '{ if ($1 == "Secret" && $2 == "key:") {print $3}}')

  inc storage bucket key list "${poolName}" "${bucketPrefix}.foo" | grep -F "admin-key"
  inc storage bucket key list "${poolName}" "${bucketPrefix}.foo" | grep -F "ro-key"
  inc storage bucket key show "${poolName}" "${bucketPrefix}.foo" admin-key
  inc storage bucket key show "${poolName}" "${bucketPrefix}.foo" ro-key

  # Test listing buckets via S3.
  s3cmdrun "${incus_backend}" "${adAccessKey}" "${adSecretKey}" ls | grep -F "${bucketPrefix}.foo"
  s3cmdrun "${incus_backend}" "${roAccessKey}" "${roSecretKey}" ls | grep -F "${bucketPrefix}.foo"

  # Test making buckets via S3 is blocked.
  ! s3cmdrun "${incus_backend}" "${adAccessKey}" "${adSecretKey}" mb "s3://${bucketPrefix}.foo2" || false
  ! s3cmdrun "${incus_backend}" "${roAccessKey}" "${roSecretKey}" mb "s3://${bucketPrefix}.foo2" || false

  # Test putting a file into a bucket.
  incusTestFile="bucketfile_${bucketPrefix}.txt"
  head -c 2M /dev/urandom > "${incusTestFile}"
  s3cmdrun "${incus_backend}" "${adAccessKey}" "${adSecretKey}" put "${incusTestFile}" "s3://${bucketPrefix}.foo"
  ! s3cmdrun "${incus_backend}" "${roAccessKey}" "${roSecretKey}" put "${incusTestFile}" "s3://${bucketPrefix}.foo" || false

  # Test listing bucket files via S3.
  s3cmdrun "${incus_backend}" "${adAccessKey}" "${adSecretKey}" ls "s3://${bucketPrefix}.foo" | grep -F "${incusTestFile}"
  s3cmdrun "${incus_backend}" "${roAccessKey}" "${roSecretKey}" ls "s3://${bucketPrefix}.foo" | grep -F "${incusTestFile}"

  # Test getting a file from a bucket.
  s3cmdrun "${incus_backend}" "${adAccessKey}" "${adSecretKey}" get "s3://${bucketPrefix}.foo/${incusTestFile}" "${incusTestFile}.get"
  rm "${incusTestFile}.get"
  s3cmdrun "${incus_backend}" "${roAccessKey}" "${roSecretKey}" get "s3://${bucketPrefix}.foo/${incusTestFile}" "${incusTestFile}.get"
  rm "${incusTestFile}.get"

  # Test setting bucket policy to allow anonymous access (also tests bucket URL generation).
  bucketURL=$(inc storage bucket show "${poolName}" "${bucketPrefix}.foo" | awk '{if ($1 == "s3_url:") {print $2}}')

  curl -sI --insecure -o /dev/null -w "%{http_code}" "${bucketURL}/${incusTestFile}" | grep -Fx "403"
  ! s3cmdrun "${incus_backend}" "${roAccessKey}" "${roSecretKey}" setpolicy deps/s3_global_read_policy.json "s3://${bucketPrefix}.foo" || false
  s3cmdrun "${incus_backend}" "${adAccessKey}" "${adSecretKey}" setpolicy deps/s3_global_read_policy.json "s3://${bucketPrefix}.foo"
  curl -sI --insecure -o /dev/null -w "%{http_code}" "${bucketURL}/${incusTestFile}" | grep -Fx "200"
  ! s3cmdrun "${incus_backend}" "${roAccessKey}" "${roSecretKey}" delpolicy "s3://${bucketPrefix}.foo" || false
  s3cmdrun "${incus_backend}" "${adAccessKey}" "${adSecretKey}" delpolicy "s3://${bucketPrefix}.foo"
  curl -sI --insecure o /dev/null -w "%{http_code}" "${bucketURL}/${incusTestFile}" | grep -Fx "403"

  # Test deleting a file from a bucket.
  ! s3cmdrun "${incus_backend}" "${roAccessKey}" "${roSecretKey}" del "s3://${bucketPrefix}.foo/${incusTestFile}" || false
  s3cmdrun "${incus_backend}" "${adAccessKey}" "${adSecretKey}" del "s3://${bucketPrefix}.foo/${incusTestFile}"

  # Test bucket quota (except dir driver which doesn't support quotas so check that its prevented).
  if [ "$incus_backend" = "dir" ]; then
    ! inc storage bucket create "${poolName}" "${bucketPrefix}.foo2" size=1MiB || false
  else
    initCreds=$(inc storage bucket create "${poolName}" "${bucketPrefix}.foo2" size=1MiB)
    initAccessKey=$(echo "${initCreds}" | awk '{ if ($2 == "access" && $3 == "key:") {print $4}}')
    initSecretKey=$(echo "${initCreds}" | awk '{ if ($2 == "secret" && $3 == "key:") {print $4}}')
    ! s3cmdrun "${incus_backend}" "${initAccessKey}" "${initSecretKey}" put "${incusTestFile}" "s3://${bucketPrefix}.foo2" || false

    # Grow bucket quota (significantly larger in order for MinIO to detect their is sufficient space to continue).
    inc storage bucket set "${poolName}" "${bucketPrefix}.foo2" size=150MiB
    s3cmdrun "${incus_backend}" "${initAccessKey}" "${initSecretKey}" put "${incusTestFile}" "s3://${bucketPrefix}.foo2"
    s3cmdrun "${incus_backend}" "${initAccessKey}" "${initSecretKey}" del "s3://${bucketPrefix}.foo2/${incusTestFile}"
    inc storage bucket delete "${poolName}" "${bucketPrefix}.foo2"
  fi

  # Cleanup test file used earlier.
  rm "${incusTestFile}"

  # Test deleting bucket via s3.
  ! s3cmdrun "${incus_backend}" "${roAccessKey}" "${roSecretKey}" rb "s3://${bucketPrefix}.foo" || false
  s3cmdrun "${incus_backend}" "${adAccessKey}" "${adSecretKey}" rb "s3://${bucketPrefix}.foo"

  # Delete bucket keys.
  inc storage bucket key delete "${poolName}" "${bucketPrefix}.foo" admin-key
  inc storage bucket key delete "${poolName}" "${bucketPrefix}.foo" ro-key
  ! inc storage bucket key list "${poolName}" "${bucketPrefix}.foo" | grep -F "admin-key" || false
  ! inc storage bucket key list "${poolName}" "${bucketPrefix}.foo" | grep -F "ro-key" || false
  ! inc storage bucket key show "${poolName}" "${bucketPrefix}.foo" admin-key || false
  ! inc storage bucket key show "${poolName}" "${bucketPrefix}.foo" ro-key || false
  ! s3cmdrun "${incus_backend}" "${adAccessKey}" "${adSecretKey}" ls || false
  ! s3cmdrun "${incus_backend}" "${roAccessKey}" "${roSecretKey}" ls || false

  # Delete bucket.
  inc storage bucket delete "${poolName}" "${bucketPrefix}.foo"
  ! inc storage bucket list "${poolName}" | grep -F "${bucketPrefix}.foo" || false
  ! inc storage bucket show "${poolName}" "${bucketPrefix}.foo" || false

  if [ "$incus_backend" = "ceph" ] || [ "$incus_backend" = "dir" ]; then
    inc storage delete "${poolName}"
  fi

  if [ "$incus_backend" = "dir" ]; then
    umount "${TEST_DIR}/${bucketPrefix}"
    rmdir "${TEST_DIR}/${bucketPrefix}"

    # shellcheck disable=SC2154
    deconfigure_loop_device "${loop_file_1}" "${loop_device_1}"
  fi
}
