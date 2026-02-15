using UnityEngine;
using System.Collections.Generic;

public class HowlScript : MonoBehaviour, SkillScript
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
        return fromPosition;
    }

    public void UseSkill(Vector3 targetPosition, GameObject wielder)
    {
    }

    public void PrepareSkill(Vector3 fromPosition, GameObject wielder)
    {
        traversableTilesScript.ClearHighlights();
        EntityScript wielderScript = wielder.GetComponent<EntityScript>();
        wielderScript.DisplayUsedSkill(skillSprite);
        float effectiveRadius = radius + wielderScript.enchantmentModifiers.radius;
        Dictionary<Vector3, GameObject> enemyLookup = enemiesScript.enemyLookup;
        List<Vector3> deltas = new List<Vector3>();
        for (float i = -effectiveRadius; i <= effectiveRadius; i++)
        {
            for (float j = -effectiveRadius; j <= effectiveRadius; j++)
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
            Vector3 position = wielder.transform.position + delta;
            if (enemyLookup.ContainsKey(position))
            {
                GameObject enemyInRange = enemyLookup[position];
                EntityScript enemyScript = enemyInRange.GetComponent<EntityScript>();
                enemyScript.IsActive = true;
            }
        }
        wielderScript.SetSkillCooldown(skillName, cooldown);
        if (wielder == player)
        {
            turnLogicScript.hasUsedAnySkill = true;
        }
    }

    void Awake()
    {
        skillName = "Howl";
        skillType = "Cantrip";
        description = "Aggro each enemy within radius";
        range = 0;
        radius = 16;
        distance = 0;
        skillDuration = 0;
        stunDuration = 0;
        cooldown = 10;
        skillSprite = Resources.Load<Sprite>("Skills/Howl");
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
