import "FungibleToken"

pub contract MultiSigAccount {
    pub let StoragePath: StoragePath
    pub let PublicPath: PublicPath
    pub let PrivatePath: PrivatePath

    pub let LinkedAccountPath: PrivatePath

    pub event AccountCreated(_ address: Address, _ signers: [Address])

    pub event ProposalCreated(_ address: Address, _ proposer: Address, _ id: UInt64,  _ title: String, _ description: String)
    pub event ProposalVoteAdded(_ address: Address, _ voter: Address, _ id: UInt64, _ vote: String)
    pub event ProposalExecuted(_ address: Address, _ id: UInt64)
    pub event ProposalRejected(_ address: Address, _ id: UInt64)

    pub resource interface AccountPublic {
        pub fun recordVote(signer: &Signer{Voter}, id: UInt64)
    }

    pub resource Account: AccountPublic {
        pub let acct: Capability<&AuthAccount>

        pub let proposals: @{UInt64: Proposal}
        pub let allowedProposalTypes: {Type: Bool}
        access(contract) let signers: {Address: Bool}

        pub fun addSigner(addr: Address) {
            self.signers[addr] = true
        }

        pub fun removeSigner(addr: Address) {
            self.signers.remove(key: addr)
        }
        
        pub fun executeProposal(id: UInt64) {
            let p = self.borrowProposal(id: id)
                ?? panic("proposal not found")

            p.execute(acct: self.acct.borrow()!)
            
            destroy self.proposals.remove(key: id)
        }

        pub fun recordVote(signer: &Signer{Voter}, id: UInt64) {
            pre {
                self.signers[signer.owner!.address] != nil: "unapproved signer"
            }
        }

        pub fun borrowProposal(id: UInt64): &Proposal? {
            return &self.proposals[id] as &Proposal?
        }

        init(cap: Capability<&AuthAccount>, signers: [Address]) {
            self.acct = cap

            self.proposals <- {}
            self.allowedProposalTypes = {}
            self.signers = {}
            for s in signers {
                self.signers[s] = true
            }
        }

        destroy () {
            destroy self.proposals
        }
    }

    pub resource interface Voter{
        pub fun getVote(id: UInt64): Bool?
    }

    pub resource Signer: Voter {
        pub let votes: {UInt64: Bool}

        pub fun getVote(id: UInt64): Bool? {
            return self.votes[id]
        }

        pub fun vote(address: Address, id: UInt64, vote: Bool) {
            pre {
                self.votes[id] == nil: "already voted" // should we let people change their votes?
            }

            let cap = getAccount(address).getCapability<&Account{AccountPublic}>(MultiSigAccount.PublicPath)
            let acct = cap.borrow() ?? panic("account not found")
            
            self.votes[id] = vote

            let signer = &self as! &Signer{Voter}
            acct.recordVote(signer: signer, id: id)
        }

        init() {
            self.votes = {}
        }
    }

    pub struct interface Executable {
        access(contract) fun execute(acct: &AuthAccount)
    }

    pub struct EditSignerExecutable: Executable {
        pub let signer: Address
        pub let add: Bool // true to add a signer, false to remove one

        access(contract) fun execute(acct: &AuthAccount) {
            let account = acct.borrow<&Account>(from: MultiSigAccount.StoragePath)!
            if self.add {
                account.addSigner(addr: self.signer)
            } else {
                account.removeSigner(addr: self.signer)
            }
        }

        init(signer: Address, add: Bool) {
            self.signer = signer
            self.add = add
        }
    }

    pub resource Proposal {
        pub let creator: Address
        pub let title: String
        pub let description: String
        pub let signers: {Address: Bool}
        pub var approvalThreshold: Int

        access(contract) let executable: {Executable}

        pub let votes: {Address: Bool}
        pub let approvals: {Address: Bool}

        pub let executed: Bool
        
        pub fun execute(acct: &AuthAccount) {
            pre {
                !self.executed: "already executed"
                self.approvals.keys.length >= self.approvalThreshold: "not enough approvals"
            }
            
            self.executable.execute(acct: acct)
        }

        init(
            creator: Address,
            title: String,
            description: String,
            executable: {Executable},
            signers: {Address: Bool},
            approvalThreshold: Int
        ) {
            self.creator = creator
            self.title = title
            self.description = description
            self.executable = executable
            self.signers = signers
            self.approvalThreshold = approvalThreshold
            
            self.executed = false
            self.votes = {}
            self.approvals = {}
        }
    }

    pub fun createAccount(payment: @FungibleToken.Vault, signers: [Address]) {
        pre {
            payment.balance >= 0.01: "insufficient balance"
        }

        self.account.borrow<&FungibleToken.Vault>(from: /storage/flowTokenVault)!.deposit(from: <-payment)
        let multiSigAccount = AuthAccount(payer: self.account)

        let cap = multiSigAccount.linkAccount(self.LinkedAccountPath) ?? panic("unable to link new account")
        let account <- create Account(cap: cap, signers: signers)

        multiSigAccount.save(<-account, to: self.StoragePath)
        multiSigAccount.link<&Account{AccountPublic}>(self.PublicPath, target: self.StoragePath)
    }

    init() {
        let identifier = "MultiSigAccount".concat(self.account.address.toString())
        self.StoragePath = StoragePath(identifier: identifier)!
        self.PrivatePath = PrivatePath(identifier: identifier)!
        self.PublicPath = PublicPath(identifier: identifier)!

        self.LinkedAccountPath = /private/MultiSigLinkedAccount
    }
 }
