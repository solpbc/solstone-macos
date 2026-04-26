import Foundation

public enum SolMacExit: Int32 {
    case success = 0
    case invalidArgs = 1
    case ipcError = 2
    case appNotRunning = 3
    case versionMismatch = 4
    case localValidation = 5
}
