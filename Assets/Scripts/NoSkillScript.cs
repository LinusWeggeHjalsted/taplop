using UnityEngine;

public class NoSkillScript : MonoBehaviour, Skill
{
    private int currentCooldown = 0;

    public string GetDescription()
    {
        return "";
    }

    public float GetRange()
    {
        return 0;
    }

    public int CurrentCooldown()
    {
        return currentCooldown;
    }

    public void ReduceCooldown(int number)
    {
    }

    public int EnemyPriority(Vector3 fromPosition)
    {
        return -1;
    }

    public void useSkill(Vector3 targetPosition, GameObject wielder)
    {
        Debug.Log("no skill equipped in this slot");
    }

    public void prepareSkill(Vector3 fromPosition, GameObject wielder)
    {
        Debug.Log("no skill equipped in this slot");
    }

}
