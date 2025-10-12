using UnityEngine;
using System.Collections.Generic;

public class SkewerScript : MonoBehaviour, Skill
{
    private string skillName;
    private string skillType;
    private string description;
    private float range;
    private Sprite skillSprite;
    private int cooldown;
    private int currentCooldown = 0;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
    public GameObject enemies;
    public EnemiesScript enemiesScript;
    public GameObject player;
    public GameObject turnLogic;
    public TurnLogicScript turnLogicScript;

    public string GetSkillName()
    {
        return skillName;
    }

    public string GetSkillType()
    {
        return skillType;
    }

    public string GetDescription()
    {
        return description;
    }

    public float GetRange()
    {
        return range;
    }

    public Sprite GetSprite()
    {
        return skillSprite;
    }

    public int GetCooldown()
    {
        return cooldown;
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
            return 1;
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
            Debug.LogError("enemy tried to use skewer without targets in range");
            return fromPosition;
        }
    }

    public void UseSkill(Vector3 targetPosition, GameObject wielder)
    {
        EntityScript wielderScript = wielder.GetComponent<EntityScript>();
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
            targetScript.IncomingDamage(wielderScript.offHandDamage * 3, wielder);
        }
        currentCooldown = cooldown;
        if (wielder == player)
        {
            turnLogicScript.hasAttacked = true;
        }
    }

    public void PrepareSkill(Vector3 fromPosition, GameObject wielder)
    {
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
    }

    void Start()
    {
        skillName = "Skewer";
        skillType = "Off Hand Skill";
        description = "Attack target for 3x damage";
        cooldown = 4;
        range = 1f;
        skillSprite = Resources.Load<Sprite>("Skill Sprites/Skewer");
        traversableTiles = GameObject.Find("Traversable Tiles");
        traversableTilesScript = traversableTiles.GetComponent<TraversableTilesScript>();
        enemies = GameObject.Find("Enemies");
        enemiesScript = enemies.GetComponent<EnemiesScript>();
        player = GameObject.Find("Player");
        turnLogic = GameObject.Find("Turn Logic");
        turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
    }
}
