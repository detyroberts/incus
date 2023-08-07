package db

import (
	"fmt"

	"github.com/lxc/incus/incus/db/cluster"
	"github.com/lxc/incus/incus/db/node"
)

// UpdateSchema updates the schema.go file of the cluster and node databases.
func UpdateSchema() error {
	err := cluster.SchemaDotGo()
	if err != nil {
		return fmt.Errorf("Update cluster database schema: %w", err)
	}

	err = node.SchemaDotGo()
	if err != nil {
		return fmt.Errorf("Update node database schema: %w", err)
	}

	return nil
}
