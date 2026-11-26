<?php
declare(strict_types=1);

// Media transfer needs an authorization result, not an idle database session.
function releaseDatabaseConnection(): void {
    global $db;
    if ($db instanceof PDO && $db->inTransaction()) throw new LogicException("Cannot release a database connection during a transaction.");
    $db=null;
}
