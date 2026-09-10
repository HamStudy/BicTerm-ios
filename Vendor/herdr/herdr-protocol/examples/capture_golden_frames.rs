use herdr_protocol::write_message;
#[path = "../tests/support/client_samples.rs"]
mod client_samples;
#[path = "../tests/support/server_samples.rs"]
mod server_samples;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let directory = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden");
    std::fs::create_dir_all(&directory)?;
    for (index, message) in client_samples::samples()?.iter().enumerate() {
        let mut file = std::fs::File::create(directory.join(format!("client-{index:02}.bin")))?;
        write_message(&mut file, message)?;
    }
    for (index, message) in server_samples::samples()?.iter().enumerate() {
        let mut file = std::fs::File::create(directory.join(format!("server-{index:02}.bin")))?;
        write_message(&mut file, message)?;
    }
    Ok(())
}
