import XCTest
@testable import BlabladorCore

final class ProteinTests: XCTestCase {
    func testSequenceAcceptsFASTAAndRefusesNonsense() throws {
        XCTAssertEqual(try Molecular.sequence(from: ">sp|P0DTC2 spike\nMFVF LVLL\nPLVS\n"), "MFVFLVLLPLVS")
        XCTAssertEqual(try Molecular.sequence(from: "mkt"), "MKT")
        XCTAssertThrowsError(try Molecular.sequence(from: "MKT123")) { error in
            XCTAssertTrue("\(error)".contains("1, 2, 3"), "the bad characters should be named: \(error)")
        }
        XCTAssertThrowsError(try Molecular.sequence(from: ">only a header\n"))
        XCTAssertThrowsError(try Molecular.sequence(from: String(repeating: "A", count: Molecular.maximumSequence + 1)))
    }

    func testFieldChecks() {
        XCTAssertTrue(Molecular.isResidueSelection("B20-140"))
        XCTAssertTrue(Molecular.isResidueSelection("A1-76"))
        // A range is required; a single residue isn't a selection the adapter takes.
        XCTAssertFalse(Molecular.isResidueSelection("A5"))
        XCTAssertFalse(Molecular.isResidueSelection("B20-"))
        XCTAssertFalse(Molecular.isResidueSelection("chain B 20-140"))
        XCTAssertTrue(Molecular.isChains("A,B"))
        XCTAssertFalse(Molecular.isChains("A B"))
        XCTAssertTrue(Molecular.isLength("40-50"))
        XCTAssertTrue(Molecular.isLength("45"))
        XCTAssertFalse(Molecular.isLength("forty"))
        XCTAssertFalse(Molecular.isFilename("../escape.pdb"))
        XCTAssertTrue(Molecular.isStructure("ATOM      1  N   MET A   1      27.3  24.2   2.7"))
        XCTAssertFalse(Molecular.isStructure("just text"))
    }

    /// The five are job APIs, so they must never be offered as chat models — while alias-fast still is one.
    func testMolecularAliasesAreNotChatModels() {
        for kind in Molecular.Kind.allCases {
            XCTAssertFalse(RemoteModel(id: kind.alias).isChatCapable, kind.alias)
        }
        XCTAssertTrue(RemoteModel(id: "alias-fast").isChatCapable)
        XCTAssertTrue(RemoteModel(id: BlabladorAPI.defaultModel).isChatCapable)
    }

    func testErrorMapping() {
        XCTAssertTrue(Molecular.failure(status: 429, body: "").isTransient)
        XCTAssertTrue(Molecular.failure(status: 503, body: "").isTransient)
        XCTAssertTrue(Molecular.failure(status: 502, body: "").isTransient)
        XCTAssertFalse(Molecular.failure(status: 400, body: "bad").isTransient)
        if case .gone = Molecular.failure(status: 404, body: "") {} else { XCTFail("404 should be gone") }
        if case .keyRejected = Molecular.failure(status: 401, body: "") {} else { XCTFail("401 should be a key problem") }
    }

    /// A finished job is not a sound result: too few steps gives a chain whose alpha carbons are far too far apart.
    func testBackboneCheck() {
        let good = pdb(spacing: 3.8, count: 20)
        let check = StructureCheck.run(onStructure: good)
        XCTAssertEqual(check.verdict, .ok)
        XCTAssertEqual(check.bonds, 19)
        XCTAssertEqual(check.plausible, 19)
        XCTAssertEqual(check.averageDistance, 3.8, accuracy: 0.01)

        let bad = StructureCheck.run(onStructure: pdb(spacing: 10, count: 20))
        XCTAssertEqual(bad.verdict, .implausible)
        XCTAssertEqual(bad.plausible, 0)
        XCTAssertTrue(bad.text.contains("not a physically plausible structure"))

        XCTAssertEqual(StructureCheck.run(onStructure: "nothing here").verdict, .unknown)
    }

    func testReadsMinimalMMCIF() {
        let cif = """
        data_structure
        loop_
        _atom_site.group_PDB
        _atom_site.label_atom_id
        _atom_site.label_asym_id
        _atom_site.Cartn_x
        _atom_site.Cartn_y
        _atom_site.Cartn_z
        ATOM CA A 0.0 0.0 0.0
        ATOM CB A 1.0 0.0 0.0
        ATOM CA A 3.8 0.0 0.0
        ATOM CA B 0.0 0.0 0.0
        """
        let chains = Structure.alphaCarbons(cif)
        XCTAssertEqual(chains["A"]?.count, 2, "only CA atoms count")
        XCTAssertEqual(chains["B"]?.count, 1)
        XCTAssertEqual(StructureCheck.run(onStructure: cif).verdict, .ok)
    }

    /// The job record follows what the shim says, and never invents progress.
    func testJobFollowsTheShim() {
        var job = MolecularJob(kind: .esmfold2, label: "", requestID: "r", parameters: Data("{}".utf8))
        job.apply(["id": "job-1", "status": "queued", "queue_position": 3, "poll_after_seconds": 42])
        XCTAssertEqual(job.remoteID, "job-1")
        XCTAssertEqual(job.state, .queued)
        XCTAssertEqual(job.queuePosition, 3)
        XCTAssertEqual(job.pollAfter, 42)
        XCTAssertTrue(job.progressText.contains("3 ahead"))
        XCTAssertFalse(job.progressText.contains("%"))

        job.apply(["status": "running", "stage": "folding"])
        XCTAssertNil(job.queuePosition, "a queue position is meaningless once it runs")
        XCTAssertEqual(job.progressText, "folding")

        job.apply(["status": "completed", "completed_at": 1_700_000_000, "retention_seconds": 3600,
                   "usage": ["gpu_seconds": 12.5]])
        XCTAssertTrue(job.isTerminal)
        XCTAssertEqual(job.result, .waiting, "a finished job's result is fetched straight away")
        XCTAssertEqual(job.gpuSeconds, 12.5)
        XCTAssertEqual(job.expires, Date(timeIntervalSince1970: 1_700_000_000 + 3600))

        // Never slower than the floor, whatever the service asks for.
        job.apply(["poll_after_seconds": 1])
        XCTAssertEqual(job.pollAfter, Molecular.minimumPoll)
    }

    func testReadsStoredAndDeflatedArchives() throws {
        let text = pdb(spacing: 3.8, count: 5)
        let zip = Zip.store([("notes.txt", Data("hello".utf8)), ("structure.pdb", Data(text.utf8))])
        let entries = ZipReader.entries(zip)
        XCTAssertEqual(entries.map(\.name), ["notes.txt", "structure.pdb"])
        XCTAssertEqual(ZipReader.read(entries[1]).flatMap { String(data: $0, encoding: .utf8) }, text)

        let files = Structure.files(in: zip)
        XCTAssertEqual(files.map(\.name), ["structure.pdb"], "only structures, and the largest first")
        XCTAssertEqual(StructureCheck.run(onArchive: zip).verdict, .ok)
        XCTAssertEqual(StructureCheck.run(onArchive: zip).file, "structure.pdb")
    }

    /// A chain of alpha carbons in a straight line, `spacing` Ångström apart.
    private func pdb(spacing: Double, count: Int) -> String {
        (0..<count).map { index in
            let x = String(format: "%8.3f", Double(index) * spacing)
            return "ATOM  \(String(format: "%5d", index + 1))  CA  ALA A\(String(format: "%4d", index + 1))    \(x)   0.000   0.000  1.00  0.00           C"
        }
        .joined(separator: "\n")
    }
}
