// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Drug Logistics & Tracking Contract
/// @author
/// @notice Track drug batches, custody transfers, locations and recalls on-chain
contract DrugLogistics {

    /// Roles in the supply chain
    enum Role { None, Manufacturer, Distributor, Transporter, Pharmacy, Regulator }

    /// Status of a drug batch
    enum Status { Created, InTransit, Received, Dispensed, Recalled }

    /// Structure that represents a drug/batch
    struct Drug {
        uint256 id;                 // unique ID for the drug batch
        string name;               // drug name
        string batchNumber;        // manufacturer batch number
        uint256 manufactureDate;   // UNIX timestamp
        string metadataURI;        // optional IPFS or other URI for certificates/specs
        address currentOwner;      // current custodian address
        Status status;             // current status
        bool exists;               // helper flag
    }

    /// Event emitted when a new drug/batch is created
    event DrugCreated(uint256 indexed drugId, string name, string batchNumber, address indexed manufacturer);

    /// Event emitted on transfer of custody
    event DrugTransferred(uint256 indexed drugId, address indexed from, address indexed to, Status status);

    /// Event emitted when location or metadata updated
    event DrugLocationUpdated(uint256 indexed drugId, address indexed updater, string location, uint256 timestamp);

    /// Event emitted when a drug is recalled
    event DrugRecalled(uint256 indexed drugId, address indexed regulator);

    /// Mapping from drugId to Drug struct
    mapping(uint256 => Drug) private drugs;

    /// Participant role mapping
    mapping(address => Role) public roles;

    /// Drug provenance: mapping drugId -> array of owners (for history)
    mapping(uint256 => address[]) private ownersHistory;

    /// Drug location/time history: drugId -> array of (location string + timestamp)
    struct LocationRecord {
        string location;
        uint256 timestamp;
        address updater;
    }
    mapping(uint256 => LocationRecord[]) private locationsHistory;

    /// Counter for generating unique drug IDs
    uint256 private nextDrugId = 1;

    /// Contract owner (admin)
    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only contract owner");
        _;
    }

    modifier onlyRole(Role expected) {
        require(roles[msg.sender] == expected, "Unauthorized role for this action");
        _;
    }

    modifier onlyParticipant() {
        require(roles[msg.sender] != Role.None, "Only registered participant");
        _;
    }

    modifier drugExists(uint256 drugId) {
        require(drugs[drugId].exists, "Drug does not exist");
        _;
    }

    constructor() {
        owner = msg.sender;
        roles[msg.sender] = Role.Regulator; // deployer can be regulator/admin by default
    }

    // ---------------------------
    // Participant management
    // ---------------------------

    /// @notice Add a participant with a role (only owner/admin)
    /// @param participant Address of participant
    /// @param role Role enum value (1..5)
    function addParticipant(address participant, Role role) external onlyOwner {
        require(participant != address(0), "Zero address");
        require(role != Role.None, "Invalid role");
        roles[participant] = role;
    }

    /// @notice Remove a participant (set role to None)
    function removeParticipant(address participant) external onlyOwner {
        roles[participant] = Role.None;
    }

    // ---------------------------
    // Drug lifecycle functions
    // ---------------------------

    /// @notice Manufacturer creates a new drug batch
    /// @param name Drug name
    /// @param batchNumber Manufacturer's batch identifier
    /// @param manufactureDate Unix timestamp (optional)
    /// @param metadataURI Optional IPFS/metadata URI
    /// @return drugId newly created drug ID
    function createDrug(
        string calldata name,
        string calldata batchNumber,
        uint256 manufactureDate,
        string calldata metadataURI
    ) external onlyRole(Role.Manufacturer) returns (uint256 drugId) {
        drugId = nextDrugId++;
        Drug storage d = drugs[drugId];
        d.id = drugId;
        d.name = name;
        d.batchNumber = batchNumber;
        d.manufactureDate = manufactureDate;
        d.metadataURI = metadataURI;
        d.currentOwner = msg.sender;
        d.status = Status.Created;
        d.exists = true;

        ownersHistory[drugId].push(msg.sender);

        emit DrugCreated(drugId, name, batchNumber, msg.sender);
    }

    /// @notice Transfer custody of a drug batch to another registered participant
    /// @param drugId ID of the drug
    /// @param to Address of the recipient (must be registered participant)
    /// @param newStatus New status after transfer (InTransit or Received typically)
    function transferDrug(uint256 drugId, address to, Status newStatus)
        external
        drugExists(drugId)
        onlyParticipant
    {
        require(to != address(0), "Cannot transfer to zero address");
        require(roles[to] != Role.None, "Recipient must be registered");
        Drug storage d = drugs[drugId];
        require(d.currentOwner == msg.sender || roles[msg.sender] == Role.Transporter, "Only current owner or transporter can transfer");
        require(newStatus != Status.Created, "Invalid new status");
        require(d.status != Status.Recalled, "Cannot transfer recalled batch");

        address previous = d.currentOwner;
        d.currentOwner = to;
        d.status = newStatus;

        ownersHistory[drugId].push(to);
        emit DrugTransferred(drugId, previous, to, newStatus);
    }

    /// @notice Update location (and optionally metadata URI) for a drug batch
    /// @param drugId ID of the drug
    /// @param location Human readable location string (could be GPS, warehouse id, etc)
    /// @param metadataURI Optional new metadata URI (e.g., updated certificate)
    function updateLocation(uint256 drugId, string calldata location, string calldata metadataURI)
        external
        drugExists(drugId)
        onlyParticipant
    {
        Drug storage d = drugs[drugId];
        require(d.status != Status.Recalled, "Drug is recalled");
        // Allow only current owner or regulators to add location updates
        require(msg.sender == d.currentOwner || roles[msg.sender] == Role.Regulator || roles[msg.sender] == Role.Transporter, "Not allowed to update location");

        locationsHistory[drugId].push(LocationRecord({
            location: location,
            timestamp: block.timestamp,
            updater: msg.sender
        }));

        if (bytes(metadataURI).length > 0) {
            d.metadataURI = metadataURI;
        }

        emit DrugLocationUpdated(drugId, msg.sender, location, block.timestamp);
    }

    /// @notice Mark a drug batch as dispensed at pharmacy (final)
    /// @param drugId ID of the drug
    function markDispensed(uint256 drugId) external drugExists(drugId) onlyRole(Role.Pharmacy) {
        Drug storage d = drugs[drugId];
        require(d.currentOwner == msg.sender, "Only current owner pharmacy can mark dispensed");
        d.status = Status.Dispensed;
        emit DrugTransferred(drugId, msg.sender, msg.sender, d.status);
    }

    /// @notice Regulator can recall a drug batch
    /// @param drugId ID of the drug to recall
    function recallDrug(uint256 drugId) external drugExists(drugId) onlyRole(Role.Regulator) {
        Drug storage d = drugs[drugId];
        d.status = Status.Recalled;
        emit DrugRecalled(drugId, msg.sender);
    }

    // ---------------------------
    // Read-only / getters
    // ---------------------------

    /// @notice Get basic drug data
    function getDrug(uint256 drugId) external view drugExists(drugId) returns (
        uint256 id,
        string memory name,
        string memory batchNumber,
        uint256 manufactureDate,
        string memory metadataURI,
        address currentOwner,
        Status status
    ) {
        Drug storage d = drugs[drugId];
        return (d.id, d.name, d.batchNumber, d.manufactureDate, d.metadataURI, d.currentOwner, d.status);
    }

    /// @notice Get owners history (provenance)
    function getOwnersHistory(uint256 drugId) external view drugExists(drugId) returns (address[] memory) {
        return ownersHistory[drugId];
    }

    /// @notice Get location history records
    function getLocationsHistory(uint256 drugId) external view drugExists(drugId) returns (LocationRecord[] memory) {
        return locationsHistory[drugId];
    }

    /// @notice Returns the role for an address
    function getRole(address participant) external view returns (Role) {
        return roles[participant];
    }

    // ---------------------------
    // Admin utilities
    // ---------------------------

    /// @notice Change contract owner (admin)
    function changeOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
        roles[newOwner] = Role.Regulator; // give regulator/admin role by default
    }

    /// @notice Emergency: adjust metadata URI (only owner/regulator)
    function forceSetMetadataURI(uint256 drugId, string calldata metadataURI) external drugExists(drugId) onlyOwner {
        drugs[drugId].metadataURI = metadataURI;
    }
}
