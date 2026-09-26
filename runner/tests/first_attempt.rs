use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

struct TempConsumer(PathBuf);

impl TempConsumer {
    fn new() -> Self {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock after epoch")
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "fswth-first-attempt-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir_all(&path).expect("create temp consumer");
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempConsumer {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn a_first_attempt_failure_is_not_retried_or_reported_green() {
    let consumer = TempConsumer::new();
    fs::write(
        consumer.path().join("fs-windows-test-harness.toml"),
        r#"
[project]
name = "first-attempt-regression"
matrix_path = "test-matrix.json"

[runner]
max_parallel = 2

[ops.fail-once]
host = "host"
command = "printf x >> attempts.log; exit 1"
expect_exit = 0
"#,
    )
    .expect("write config");
    fs::write(
        consumer.path().join("test-matrix.json"),
        r#"{
  "scenarios": {
    "fails-first": {
      "recipe": [ { "op": "fail-once" } ]
    }
  }
}"#,
    )
    .expect("write matrix");

    let output = Command::new(env!("CARGO_BIN_EXE_run-matrix"))
        .current_dir(consumer.path())
        .output()
        .expect("run matrix");
    let stderr = String::from_utf8_lossy(&output.stderr);

    assert_eq!(output.status.code(), Some(101), "stderr:\n{stderr}");
    assert_eq!(
        fs::read(consumer.path().join("attempts.log")).expect("attempt log"),
        b"x",
        "the failing command must execute exactly once"
    );
    assert!(
        stderr.contains("failed on first attempt"),
        "stderr:\n{stderr}"
    );
    assert!(!stderr.contains("retrying"), "stderr:\n{stderr}");

    let result: serde_json::Value = serde_json::from_slice(
        &fs::read(
            consumer
                .path()
                .join("test-diagnostics/matrix/fails-first/result.json"),
        )
        .expect("result.json"),
    )
    .expect("parse result.json");
    assert_eq!(result["status"], "failed");
}
