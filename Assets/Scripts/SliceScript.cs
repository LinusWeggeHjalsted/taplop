using UnityEngine;
using System.Collections.Generic;

public class SliceScript : MonoBehaviour, Skill
{
    public string description = "Basic sword attack";
    public float range = 1f;
    public int cooldown = 0;
    private int currentCooldown = 0;
    public GameObject sword;
    public SwordScript swordScript;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
    public GameObject enemies;
    public EnemiesScript enemiesScript;
    public GameObject player;
    public GameObject turnLogic;
    public TurnLogicScript turnLogicScript;
    
    public string GetDescription()
    {
        return description;
    }

    public float GetRange()
    {
        return range;
    }

    public int CurrentCooldown()
    {
        return currentCooldown;
    }

    public void ReduceCooldown(int number)
    {
        currentCooldown -= number;
    }

    public int EnemyPriority(Vector3 fromPosition)
    {
        if (currentCooldown > 0)
        {
            return -1;
        }
        Vector3 playerPosition = player.transform.position;
        float distanceToPlayer = traversableTilesScript.Distance(fromPosition, playerPosition);
        if (distanceToPlayer > range)
        {
            return -1;
        }
        else
        {
            return 3;
        }
    }

    public Vector3 EnemySelectTarget(Vector3 fromPosition)
    {
        Dictionary<Vector3, GameObject> tileLookup = traversableTilesScript.tileLookup;
        Vector3 playerPosition = player.transform.position;
        GameObject playerTile = tileLookup[playerPosition];
        TileScript tileScript = playerTile.GetComponent<TileScript>();
        if (tileScript.IsHighlighted)
        {
            return playerPosition;
        }
        else
        {
            Debug.LogError("enemy tried to use slice without targets in range");
            return fromPosition;
        }
    }

    public void UseSkill(Vector3 targetPosition, GameObject wielder)
    {
        Debug.Log(wielder.name + " using slice");
        Dictionary<Vector3, GameObject> enemyLookup = enemiesScript.enemyLookup;
        GameObject target = null;
        if (enemyLookup.ContainsKey(targetPosition))
        {
            target = enemyLookup[targetPosition];
        }
        if (targetPosition == player.transform.position)
        {
            target = player;
        }
        if (target != null)
        {
            EntityScript targetScript = target.GetComponent<EntityScript>();
            targetScript.IncomingDamage(swordScript.damage, wielder);
        }
    }

    public void PrepareSkill(Vector3 fromPosition, GameObject wielder)
    {
        Debug.Log(wielder.name + " preparing slice");
        traversableTilesScript.ClearHighlights();
        Dictionary<Vector3, GameObject> tileLookup = traversableTilesScript.tileLookup;
        List<Vector3> deltas = new List<Vector3>();
        for (float i = -range; i <= range; i++)
        {
            for (float j = -range; j <= range; j++)
            {
                if (i == 0 && j == 0)
                {
                    continue;
                }
                else
                {
                    Vector3 delta = new Vector3(i, j, 0);
                    deltas.Add(delta);
                }
            }
        }
        foreach (Vector3 delta in deltas)
        {
            Vector3 targetPosition = fromPosition + delta;
            if (!tileLookup.ContainsKey(targetPosition))
            {
                continue;
            }
            if (enemiesScript.enemyLookup.ContainsKey(fromPosition))
            {
                if (player.transform.position == targetPosition)
                {
                    GameObject targetTile = tileLookup[targetPosition];
                    TileScript targetTileScript = targetTile.GetComponent<TileScript>();
                    targetTileScript.IsHighlighted = true;
                }
            }
            else if (fromPosition == player.transform.position)
            {
                if (enemiesScript.enemyLookup.ContainsKey(targetPosition))
                {
                    GameObject targetTile = tileLookup[targetPosition];
                    TileScript targetTileScript = targetTile.GetComponent<TileScript>();
                    targetTileScript.IsHighlighted = true;
                }
            }
        }
        Debug.Log("highlighted possible targets");
    }

    void Start()
    {
        sword = this.transform.parent.gameObject;
        swordScript = sword.GetComponent<SwordScript>();
        traversableTiles = GameObject.Find("Traversable Tiles");
        traversableTilesScript = traversableTiles.GetComponent<TraversableTilesScript>();
        enemies = GameObject.Find("Enemies");
        enemiesScript = enemies.GetComponent<EnemiesScript>();
        player = GameObject.Find("Player");
        turnLogic = GameObject.Find("Turn Logic");
        turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
    }
}
