using UnityEngine;
using System.Collections.Generic;
using System.Linq;

public class FocusScript : MonoBehaviour, SkillScript
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
            GameObject[] equippedSkills = enemyScript.equippedSkills;
            for (int i = 0; i < equippedSkills.Length; i++)
            {
                GameObject equippedSkill = equippedSkills[i];
                if (equippedSkill == null)
                {
                    continue;
                }
                if (i == 1 || i == 2) // currently only place where weapon skills with cooldowns exist
                {
                    SkillScript equippedSkillScript = equippedSkill.GetComponent<SkillScript>();
                    if (enemyScript.GetSkillCooldown(equippedSkillScript.GetSkillName()) > 0)
                    {
                        return 0;
                    }
                }
                // to-do - this is unnecessarily going through all skills but it's fine for now
            }
            return -1;
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
        GameObject[] equippedSkills = wielderScript.equippedSkills;
        for (int i = 0; i < equippedSkills.Length; i++)
        {
            GameObject equippedSkill = equippedSkills[i];
            if (equippedSkill == null)
            {
                continue;
            }
            SkillScript equippedSkillScript = equippedSkill.GetComponent<SkillScript>();
            if (i == 1 || i == 2) // currently only place where weapon skills with cooldowns exist
            {
                wielderScript.SetSkillCooldown(equippedSkillScript.GetSkillName(), 0);
            }
            // to-do - this is unnecessarily going through all skills but it's fine for now
        }
        wielderScript.SetSkillCooldown(skillName, cooldown);
        if (wielder == player)
        {
            turnLogicScript.hasUsedAnySkill = true;
        }
    }

    void Awake()
    {
        skillName = "Focus";
        skillType = "Cantrip";
        description = "Reset each equipped weapon skill cooldown";
        range = 0;
        radius = 0;
        distance = 0;
        skillDuration = 0;
        stunDuration = 0;
        cooldown = 10;
        skillSprite = Resources.Load<Sprite>("Skills/Focus");
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
