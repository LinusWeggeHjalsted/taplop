using UnityEngine;
using System.Collections.Generic;
using System.Linq;

public class BlinkScript : MonoBehaviour, SkillScript
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
        else
        {
            return 0;
        }
    }

    public Vector3 EnemySelectTarget(Vector3 fromPosition, GameObject enemy)
    {
        EntityScript enemyScript = enemy.GetComponent<EntityScript>();
        float effectiveRange = range + enemyScript.enchantmentModifiers.range;
        Dictionary<Vector3, GameObject> highlightedTileLookup = traversableTilesScript.highlightedTileLookup;
        List<Vector3> targetPositions = new List<Vector3>();
        foreach (Vector3 targetPosition in highlightedTileLookup.Keys)
        {
            if (traversableTilesScript.Distance(fromPosition, targetPosition) <= effectiveRange)
            {
                targetPositions.Add(targetPosition);
            }
        }
        // sort targetPositions by distance to player
        // use walking distance when path exists, otherwise fall back to straight-line distance
        targetPositions = targetPositions.OrderBy(pos => {
            float walkingDist = traversableTilesScript.WalkingDistance(pos, player.transform.position);
            if (walkingDist == float.MaxValue)
            {
                return traversableTilesScript.Distance(pos, player.transform.position);
            }
            else
            {
                return walkingDist;
            }
        }).ToList();
        return targetPositions[0];
    }

    public void UseSkill(Vector3 targetPosition, GameObject wielder)
    {
        traversableTilesScript.ClearHighlights();
        EntityScript wielderScript = wielder.GetComponent<EntityScript>();
        wielderScript.DisplayUsedSkill(skillSprite);
        wielderScript.SetSkillCooldown(skillName, cooldown);
        wielderScript.MoveTo(targetPosition);
        if (wielder == player)
        {
            turnLogicScript.hasUsedAnySkill = true;
        }
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
                Vector3 delta = new Vector3(i, j, 0);
                deltas.Add(delta);
            }
        }
        List<Vector3> targetPositions = new List<Vector3>();
        foreach (Vector3 delta in deltas)
        {
            Vector3 targetPosition = fromPosition + delta;
            if (tileLookup.ContainsKey(targetPosition))
            {
                GameObject targetTile = tileLookup[targetPosition];
                TileScript targetTileScript = targetTile.GetComponent<TileScript>();
                if (!targetTileScript.isOccupied)
                {
                    targetTileScript.IsHighlighted = true;
                }
            }
        }
    }

    void Awake()
    {
        skillName = "Blink";
        skillType = "Cantrip";
        description = "Teleport";
        range = 3f;
        radius = 0;
        distance = 0;
        skillDuration = 0;
        stunDuration = 0;
        cooldown = 3;
        skillSprite = Resources.Load<Sprite>("Skills/Blink");
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
