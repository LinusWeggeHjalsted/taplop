using UnityEngine;
using System.Collections.Generic;

public class BashScript : MonoBehaviour, SkillScript
{
    private string skillName;
    private string skillType;
    private string description;
    private float range;
    private float radius;
    private float distance;
    private int skillDuration;
    private int stunDuration;
    private int cooldown;
    private Sprite skillSprite;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
    public GameObject enemies;
    public EnemiesScript enemiesScript;
    public GameObject player;
    public GameObject turnLogic;
    public TurnLogicScript turnLogicScript;
    private int _skillBarPosition;
    public int skillBarPosition
    {
        get
        {
            return _skillBarPosition;
        }
        set
        {
            _skillBarPosition = value;
        }
    }
    
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

    public float GetRadius()
    {
        return radius;
    }

    public float GetDistance()
    {
        return distance;
    }

    public int GetSkillDuration()
    {
        return skillDuration;
    }

    public int GetStunDuration()
    {
        return stunDuration;
    }

    public Sprite GetSprite()
    {
        return skillSprite;
    }

    public int GetCooldown()
    {
        return cooldown;
    }

    public int EnemyPriority(Vector3 fromPosition, GameObject enemy)
    {
        EntityScript enemyScript = enemy.GetComponent<EntityScript>();
        if (enemyScript.GetSkillCooldown(skillName) > 0)
        {
            return -1;
        }
        float effectiveRange = range + enemyScript.enchantmentModifiers.range;
        Vector3 playerPosition = player.transform.position;
        float distanceToPlayer = traversableTilesScript.Distance(fromPosition, playerPosition);
        if (distanceToPlayer > effectiveRange)
        {
            return -1;
        }
        else
        {
            // Check if knockback would cause collision (same logic as Knockback in EntityScript)
            float effectiveDistance = distance + enemyScript.enchantmentModifiers.distance;
            Vector3 positionDelta = playerPosition - fromPosition;
            // Normalize to single tile direction
            if (positionDelta.x != 0)
            {
                positionDelta.x = positionDelta.x / Mathf.Abs(positionDelta.x);
            }
            if (positionDelta.y != 0)
            {
                positionDelta.y = positionDelta.y / Mathf.Abs(positionDelta.y);
            }

            Dictionary<Vector3, GameObject> tileLookup = traversableTilesScript.tileLookup;
            bool hitObstacle = false;

            // Check each position from nearest to farthest
            for (int i = 1; i <= effectiveDistance; i++)
            {
                Vector3 checkPosition = playerPosition + i * positionDelta;
                if (tileLookup.ContainsKey(checkPosition))
                {
                    GameObject tile = tileLookup[checkPosition];
                    TileScript tileScript = tile.GetComponent<TileScript>();
                    bool isOccupied = tileScript.isOccupied;
                    // Also check if an enemy is at this position
                    if (enemiesScript != null)
                    {
                        Dictionary<Vector3, GameObject> enemyLookup = enemiesScript.enemyLookup;
                        if (enemyLookup.ContainsKey(checkPosition))
                        {
                            isOccupied = true;
                        }
                    }
                    if (isOccupied)
                    {
                        hitObstacle = true;
                        break;
                    }
                }
                else
                {
                    // Hit edge of map
                    hitObstacle = true;
                    break;
                }
            }
            return hitObstacle ? 2 : 3;
        }
    }

    public Vector3 EnemySelectTarget(Vector3 fromPosition, GameObject enemy)
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
            return fromPosition;
        }
    }

    public void UseSkill(Vector3 targetPosition, GameObject wielder)
    {
        traversableTilesScript.ClearHighlights();
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
            SoundControllerScript.Instance.PlayAttackSound();
            wielderScript.Attack(wielderScript.mainHandDamage, target);
            float preciseCollisionDamage = (float)wielderScript.mainHandDamage / 2;
            float effectiveDistance = distance + wielderScript.enchantmentModifiers.distance;
            EntityScript targetScript = target.GetComponent<EntityScript>();
            targetScript.Knockback(wielder.transform.position, wielder, (int)preciseCollisionDamage, effectiveDistance);
        }
        if (wielder == player)
        {
            turnLogicScript.hasAttacked = true;
            turnLogicScript.hasUsedAnySkill = true;
        }
        wielderScript.UsedSkill(this, targetPosition);
    }

    public void PrepareSkill(Vector3 fromPosition, GameObject wielder)
    {
        traversableTilesScript.ClearHighlights();
        EntityScript wielderScript = wielder.GetComponent<EntityScript>();
        float effectiveRange = range + wielderScript.enchantmentModifiers.range;
        Dictionary<Vector3, GameObject> tileLookup = traversableTilesScript.tileLookup;
        List<Vector3> deltas = new List<Vector3>();
        for (float i = -effectiveRange; i <= effectiveRange; i++)
        {
            for (float j = -effectiveRange; j <= effectiveRange; j++)
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

    void Awake()
    {
        skillName = "Bash";
        skillType = "Main Hand Skill";
        description = "Attack and knockback target, dealing +0.5x damage on collision";
        range = 1f;
        radius = 0;
        distance = 1f;
        skillDuration = 0;
        stunDuration = 0;
        cooldown = 0;
        skillSprite = Resources.Load<Sprite>("Skills/Bash");
    }

    void Start()
    {
        if (LevelScript.Instance != null)
        {
            traversableTiles = LevelScript.Instance.traversableTiles;
            traversableTilesScript = LevelScript.Instance.traversableTilesScript;
            enemies = LevelScript.Instance.enemies;
            enemiesScript = LevelScript.Instance.enemiesScript;
            player = LevelScript.Instance.player;
            turnLogic = LevelScript.Instance.turnLogic;
            turnLogicScript = LevelScript.Instance.turnLogicScript;
        }
    }
}
